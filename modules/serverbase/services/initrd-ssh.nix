{
  config,
  lib,
  ...
}:

# An sshd inside the initrd, so a machine that stops to ask for a disk passphrase can be answered from anywhere
# rather than only from a monitor plugged into it.
#
# This is a module rather than a few lines on the machine that needs it, for one reason: the machine that needs it
# configures its root through disko and its NIC through hardware, so a check could never reach that configuration -
# and an untested recovery path is not a recovery path. tests/base-initrd-ssh.nix drives these options on a node it
# can boot, and connects to it.
let
  cfg = config.setup.initrdSsh;
in
{
  options.setup.initrdSsh = with lib; {
    enable = mkEnableOption ''
      an sshd in the initrd.

      Turn this on together with whatever makes the initrd stop - an encrypted root, typically. On a machine that
      boots straight through there is nothing to connect to, and an sshd listening for the seconds it takes to
      reach stage 2 is attack surface bought for nothing
    '';

    port = mkOption {
      type = types.port;
      default = 2222;
      description = ''
        Deliberately not 22. The initrd and the running system are different hosts as far as `known_hosts` is
        concerned - different host keys, necessarily, since the initrd's is readable by anyone who can read the
        boot partition. Sharing a port means `REMOTE HOST IDENTIFICATION HAS CHANGED` on every single boot, which
        teaches you to ignore the one warning that is worth reading. A separate port gives each its own entry.
      '';
    };

    interface = mkOption {
      type = types.str;
      default = "eth0";
      description = ''
        The interface the initrd brings up with DHCP. Matched by name rather than by MAC: serverbase sets
        `net.ifnames=0` for every machine, so this is what the kernel calls the first NIC - and a MAC address would
        put identifiable hardware in a public repository for no gain.
      '';
    };

    kernelModules = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "igc" ];
      description = ''
        The NIC driver, which the initrd does not otherwise carry. Read it off the machine rather than guessing:
        `basename "$(readlink -f /sys/class/net/eth0/device/driver)"`. Wrong or missing, the initrd comes up with
        no network and the machine is unreachable at exactly the moment this exists for.
      '';
    };

    hostKeyFile = mkOption {
      type = types.either types.str types.path;
      default = "/etc/secrets/initrd/ssh_host_ed25519_key";
      description = ''
        A **dedicated** key, never the machine's real host key.

        Given as a *string* - the default - it is a path on the machine, and `boot.initrd.network.ssh` routes it
        through `boot.initrd.secrets`, so the bootloader installer appends it at `nixos-rebuild boot` time and the
        private key is never in `/nix/store` and never in git. It does land unencrypted in the initrd, and
        therefore on an unencrypted boot partition: whoever can read that can impersonate this initrd, and
        impersonating the initrd is how a typed passphrase is harvested. That is the whole reason it must not be
        the real host key.

        Create it once, on the machine, before the first `nixos-rebuild boot` that carries this - missing, the
        bootloader install fails rather than the evaluation:

        ```
        sudo mkdir -p /etc/secrets/initrd
        sudo ssh-keygen -t ed25519 -N "" -f /etc/secrets/initrd/ssh_host_ed25519_key
        ```

        Rotating it has a trap: `boot.initrd.secrets` copies the file without making the initrd depend on its
        *content*, so replacing the key alone leaves the toplevel unchanged, the installed generation is not
        rebuilt, and the old key stays on the boot partition. Change something in the configuration too.

        Given as a *path* it is a store path instead, which is world-readable and is only appropriate in a test.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    boot.initrd = {
      availableKernelModules = cfg.kernelModules;

      systemd.network = {
        enable = true;
        networks."10-${cfg.interface}" = {
          matchConfig.Name = cfg.interface;
          networkConfig.DHCP = "ipv4";
          linkConfig.RequiredForOnline = "routable";
        };
      };

      network.ssh = {
        enable = true;
        inherit (cfg) port;
        hostKeys = [ cfg.hostKeyFile ];
        # One source of truth with the running system's. The initrd logs in as root, so these become root's
        # authorized keys there.
        authorizedKeys = config.users.users.${config.setup.username}.openssh.authorizedKeys.keys;
      };
    };
  };
}
