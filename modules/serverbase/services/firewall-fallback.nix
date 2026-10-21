{
  lib,
  pkgs,
  config,
  ...
}:

# The firewall fails closed. The nftables ruleset loads in one transaction, so if the kernel refuses one expression in
# it - a module a kernel was built without, a vendor kernel above all - nothing loads, and the machine would run with no
# firewall at all, every service it has reachable, until someone noticed. When `nftables.service` fails to start, this
# loads a ruleset of its own instead: everything dropped but loopback and ssh, so the machine is closed and still
# reachable to be fixed.
#
# It is built only of what nf_tables does without any module of its own (payload, cmp, meta, immediate), in an `ip` and an
# `ip6` table rather than `inet`, so that it loads on any kernel that has nftables at all; the fallback that needs a
# module is the fallback that fails with the firewall. Tracking connections needs NFT_CT, so it is tried on its own
# afterwards: with it, what this machine opens outward gets its answers; without it, only ssh in works.
#
# A reload that fails needs none of this: the transaction is refused whole and the rules already loaded stay. And the
# next start that succeeds removes these tables in the same transaction (`extraDeletions`), so fixing the firewall is
# all it takes to leave this state.
let
  table = "fallback-firewall";
  families = [
    "ip"
    "ip6"
  ];
  ssh = lib.concatMapStringsSep ", " toString config.services.openssh.ports;
  ruleset = pkgs.writeText "firewall-fallback.nft" (
    lib.concatMapStrings (family: ''
      table ${family} ${table} {
        chain input {
          type filter hook input priority filter; policy drop;
          iifname "lo" accept
          tcp dport { ${ssh} } accept
        }
        chain forward {
          type filter hook forward priority filter; policy drop;
        }
      }
    '') families
  );
  connectionTracking = pkgs.writeText "firewall-fallback-ct.nft" (
    lib.concatMapStrings (family: ''
      insert rule ${family} ${table} input ct state established,related accept
    '') families
  );
  nft = "${pkgs.nftables}/bin/nft";
in
{
  config = lib.mkIf config.networking.nftables.enable {
    networking.nftables.extraDeletions = lib.concatMapStrings (family: ''
      table ${family} ${table}
      delete table ${family} ${table}
    '') families;

    systemd.services.nftables.onFailure = [ "firewall-fallback.service" ];

    systemd.services.firewall-fallback = {
      description = "Closed firewall, in place of the nftables one that failed to load";
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = [
          "${nft} -f ${ruleset}"
          # `-` : without NFT_CT the fallback still stands, it only answers nothing this machine asked for
          "-${nft} -f ${connectionTracking}"
        ];
        CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_NETLINK"
        ];
        SystemCallArchitectures = "native";
      };
    };
    # the real firewall coming back takes this one's place
    systemd.services.nftables.conflicts = [ "firewall-fallback.service" ];
  };
}
