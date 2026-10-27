{ config, lib, ... }:
let
  inherit (config.setup.ipv6) enable;
  # networkd writes `disable_ipv6=0` back on any link whose .network wants an IPv6 link-local address, which is the
  # default, so the sysctls alone are undone as soon as a link comes up. Extending the submodule type sets this on every
  # unit, including the ones nixpkgs generates from `networking.interfaces` and `networking.useDHCP`.
  noIPv6Network = lib.types.attrsOf (
    lib.types.submodule {
      config = lib.mkIf (!enable) {
        networkConfig = {
          LinkLocalAddressing = lib.mkDefault "no";
          IPv6AcceptRA = lib.mkDefault false;
        };
      };
    }
  );
in
{
  options = {
    setup.ipv6.enable = lib.mkEnableOption "IPv6 on the machine's links";
    systemd.network.networks = lib.mkOption { type = noIPv6Network; };
    boot.initrd.systemd.network.networks = lib.mkOption { type = noIPv6Network; };
  };

  config = lib.mkIf (!enable) {
    # Writing `all` also turns it off on the links that already exist, and `default` on the ones created later. The
    # kernel keeps the protocol, so services listening on `[::]` still accept IPv4; `ipv6.disable=1` would make every
    # AF_INET6 socket fail instead.
    networking.enableIPv6 = false;
    systemd.network.networks."99-ethernet-default-dhcp".DHCP = lib.mkIf (
      config.networking.useDHCP && config.networking.useNetworkd
    ) (lib.mkForce "ipv4");
  };
}
