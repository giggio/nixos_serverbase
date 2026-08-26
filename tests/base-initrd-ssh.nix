{
  inputs,
  lib,
  testNodes,
  ...
}:

# Covers modules/serverbase/services/initrd-ssh.nix by booting a machine, stopping it in the initrd and connecting
# to it - which is the only way this feature can be shown to work at all. Everything about it is invisible from the
# running system: by the time you can log in normally, the initrd and its sshd are gone.
#
# It exists because of what it protects. On a machine with an encrypted root the initrd is where the passphrase is
# typed, and if its sshd does not come up the machine is unreachable at exactly that moment - a recovery path that
# fails only when it is needed is worse than none, because it gets planned around.
#
# WHAT THIS CANNOT SHOW YOU: the DHCP half. A nixosTest VLAN has no DHCP server on it, so the address is set
# statically here while leaving the module's own network unit in place - the unit under test is the one that runs,
# only its addressing is overridden. Whether `matchConfig.Name` matches the real NIC and whether a lease actually
# arrives is proven by the VM rehearsal in PLAN_ENCRYPTION.md step 8a, on a machine with a real network.
let
  # the snakeoil pair nixpkgs ships for exactly this, so no key material is generated or committed here
  # A genuine PATH, and `/. +` is what makes it one. `inputs.nixpkgs` is a flake, so `inputs.nixpkgs + "/x"`
  # coerces through outPath and yields a *string* carrying store context - and boot.initrd.network.ssh feeds each
  # host key through `boot.initrd.secrets` as an ATTRIBUTE NAME, which may not carry context:
  #
  #     error: the string '/nix/store/...' is not allowed to refer to a store path
  #
  # A path takes the other branch of the module's `isString` test and is embedded in the initrd directly, which is
  # also what a test needs: no bootloader runs here, so nothing would ever append a secret.
  # `unsafeDiscardStringContext` because Nix refuses to append a context-carrying string to a path at all. The
  # context is not lost, only re-derived: coercing the resulting path back into the store gives it its own, so the
  # test still depends on the files it reads.
  keyDir =
    /. + (builtins.unsafeDiscardStringContext "${inputs.nixpkgs}/nixos/tests/initrd-network-ssh");
  clientPubKey = lib.fileContents (keyDir + "/id_ed25519.pub");
  hostPubKey = lib.fileContents (keyDir + "/ssh_host_ed25519_key.pub");
  user = "giggio";
  port = 2222;
in
{
  name = "base-initrd-ssh";

  nodes = {
    server =
      { config, ... }:
      {
        imports = [
          testNodes.base
          {
            setup = {
              hostName = "server";
              username = user;
            };
          }
        ];

        # holds the boot in the initrd and gives the driver a way in, so the test can look at the initrd rather
        # than race it. switch_root() below lets the boot carry on.
        testing.initrdBackdoor = true;

        setup.initrdSsh = {
          enable = true;
          # eth1 is the VLAN interface a nixosTest node gets; the real machines use eth0. Overriding it here is
          # also the only coverage the `interface` option has.
          interface = "eth1";
          kernelModules = [ "virtio_net" ];
          # A PATH rather than a string, which is the one case the option's default is not: it puts the key in the
          # store instead of routing it through boot.initrd.secrets, because a test VM installs no bootloader and
          # nothing would ever append it. Right here, wrong on a real machine.
          hostKeyFile = keyDir + "/ssh_host_ed25519_key";
        };

        # added alongside the machine's real key, which the module reads off the user
        users.users.${user}.openssh.authorizedKeys.keys = [ clientPubKey ];

        # see WHAT THIS CANNOT SHOW YOU above. Merged into the module's own unit rather than replacing it.
        boot.initrd.systemd.network.networks."10-eth1" = {
          networkConfig.DHCP = lib.mkForce "no";
          address = [ "${config.networking.primaryIPAddress}/24" ];
        };
      };

    client =
      { ... }:
      {
        imports = [
          testNodes.base
          {
            setup = {
              hostName = "client";
              username = user;
            };
          }
        ];
        environment.etc."sshKey" = {
          source = keyDir + "/id_ed25519";
          mode = "0600";
        };
      };
  };

  # takes `nodes` so the server can be addressed by IP. Its name does not resolve on the client: nixosTest writes
  # the node names into /etc/hosts, and an initrd has no /etc/hosts of the host's - but the failure showed up on
  # the CLIENT, which does, so something in the base configuration is shadowing it. Not worth chasing for a test
  # that has the address available at build time anyway.
  testScript =
    { nodes, ... }: # python
    ''
      server_ip = "${nodes.server.networking.primaryIPAddress}"

      start_all()
      client.wait_for_unit("network.target")
      server.wait_for_unit("initrd.target")

      ssh = (
          "ssh -p ${toString port} -i /etc/sshKey"
          " -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
          " -o BatchMode=yes -o ConnectTimeout=10"
      )

      with subtest("the initrd's sshd is listening, and on 2222 rather than 22"):
          client.wait_until_succeeds(f"nc -z {server_ip} ${toString port}", timeout=60)
          # 22 is what the running system uses. An initrd answering there too would mean one known_hosts entry for
          # two different host keys, and a changed-host-key warning on every boot.
          client.fail(f"nc -z -w 2 {server_ip} 22")

      with subtest("it serves the host key it was configured with"):
          # the point of a persistent, dedicated key: an initrd generating one per boot could never be verified,
          # and one sharing the machine's real key would put that key on the boot partition
          scanned = client.succeed(f"ssh-keyscan -p ${toString port} -t ed25519 {server_ip} 2>/dev/null")
          expected = "${hostPubKey}".split()[1]
          assert expected in scanned, f"the initrd is serving a different host key: {scanned}"

      with subtest("the configured key gets a root shell in the initrd"):
          # root, not ${user}: the initrd has one account, and the module feeds the user's authorized keys to it
          whoami = client.succeed(f"{ssh} root@{server_ip} whoami").strip()
          assert whoami == "root", f"logged in as '{whoami}', expected root"

          # proves it really is the initrd and not an early stage 2
          client.succeed(f"{ssh} root@{server_ip} 'test -e /etc/initrd-release'")

      with subtest("an unknown key is refused"):
          # single-quoted on the python side, and an empty argument written as a pair of DOUBLE quotes: a pair
          # of single quotes here would terminate the Nix indented string this script lives in
          client.succeed('ssh-keygen -t ed25519 -N "" -f /root/unknown-key')
          client.fail(
              "ssh -p ${toString port} -i /root/unknown-key"
              " -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
              f" -o BatchMode=yes -o ConnectTimeout=10 root@{server_ip} true"
          )

      with subtest("the boot carries on afterwards, and takes the initrd sshd with it"):
          server.switch_root()
          server.wait_for_unit("multi-user.target")
          # the running system's sshd, on 22, with its own host key - a different host entirely
          client.wait_until_succeeds(f"nc -z {server_ip} 22", timeout=60)
          client.fail(f"nc -z -w 2 {server_ip} ${toString port}")

      for node in [server, client]:
          (_, failed) = node.systemctl("--failed --quiet")
          node.log(f"systemctl --failed output: {failed}")
          assert "" == failed, "Expected no failed units and got: " + failed
    '';
}
