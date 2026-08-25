{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  # WHETHER THIS MACHINE'S ROOT IS ALREADY A LUKS CONTAINER. It is not, and flipping this is NOT what encrypts it.
  #
  # This describes an END STATE, the way `bindState` does for the application-state container: disko only
  # partitions when its own format script is run, so on a machine that already exists all this attribute decides is
  # what `fileSystems."/"` and `boot.initrd.luks.devices` are generated as. Set true on a machine whose root is
  # still plain ext4 and the next boot looks for `/dev/mapper/cryptroot`, does not find it, and stops in the
  # initrd. So the order is: convert the disk first, flip this second, and the reboot between them is the test.
  #
  # The conversion is `cryptsetup reencrypt --encrypt --reduce-device-size 32M` from a live USB, in place, on
  # /dev/disk/by-partlabel/disk-main-nixos. It is the one step in the whole encryption plan with no rollback except
  # a restore. See PLAN_ENCRYPTION.md step 8a.
  #
  # Only the MAPPER NAME below has to agree with anything, and it agrees with itself: the initrd names the mapping
  # when it unlocks, so `cryptroot` here produces /dev/mapper/cryptroot there whatever the on-disk container is
  # called. There is deliberately no `--label`, because nothing reads one and a value that must match but is never
  # checked is a trap rather than a safeguard.
  rootEncrypted = false;
in
{
  imports = [
    inputs.nixos-hardware.nixosModules.gmktec-nucbox-g3-plus
    inputs.disko.nixosModules.disko
  ];

  boot.loader.systemd-boot.enable = true; # using UEFI and not GRUB

  systemd.services."serial-getty@ttyACM0" = {
    enable = true;
    # NOT wanted by getty.target in a VM, where /dev/ttyACM0 does not exist and never will. `wantedBy` makes
    # getty.target require the device unit, systemd waits DefaultDeviceTimeoutSec for it, and multi-user.target is
    # therefore not reached for 90 seconds - during which `systemctl is-system-running` answers `starting` and
    # nothing that reports on boot state can report anything. That cost 90 seconds of every dev VM boot and looked,
    # from the outside, exactly like the encrypted-state units hanging the boot. They were not; this was.
    #
    # The udev rule below is what actually starts the console on the real machine when the CH340 bridge appears, so
    # nothing is lost. Keeping the `wantedBy` on hardware is deliberate belt and braces: that console is the
    # recovery path for a machine whose disk encryption depends on a box on the LAN. It does mean a gmktec1 booted
    # with the bridge unplugged waits the same 90 seconds - worth knowing, not worth risking the console over.
    wantedBy = lib.optionals (!config.setup.isVM) [ "getty.target" ];
    overrideStrategy = "asDropin";
    environment.TERM = "vt102";
    serviceConfig.ExecStart = [
      ""
      "${pkgs.util-linux}/bin/agetty --login-program ${pkgs.shadow}/bin/login --issue-file /etc/issue:/etc/issue.d:/run/issue:/run/issue.d %I 115200"
    ];
  };

  services.udev.extraRules = ''
    KERNEL=="ttyACM0", TAG+="systemd", ENV{SYSTEMD_WANTS}="serial-getty@ttyACM0.service"
  '';

  # SSH INTO THE INITRD, so the passphrase prompt is reachable from anywhere rather than only from a monitor
  # plugged into the box. Gated on the same flag as the layout, because the two are one feature: without an
  # encrypted root the initrd never pauses, so there is nothing to connect to and an sshd listening for the few
  # seconds it takes to reach stage 2 is attack surface bought for nothing.
  #
  # This is not a convenience. This machine sets no `console=` kernel parameter, so the prompt goes to tty0 - the
  # HDMI console - and the CH340 bridge above is a getty started by a udev rule once userspace is up, far too late
  # to type a passphrase into. Without this, every boot between the conversion and the TPM enrolment needs someone
  # standing at the machine with a monitor.
  boot.initrd = lib.mkIf rootEncrypted {
    # The whole of what the initrd needs the network for. `igc` is the Intel I226-V on this board - verified on the
    # machine 2026-08-25, `eth0` -> `igc` - and nothing else in the initrd touches the network.
    availableKernelModules = [ "igc" ];

    systemd.network = {
      enable = true;
      # `eth0` rather than a MAC or a predictable name: serverbase sets `net.ifnames=0` for every machine, so this
      # is the name the kernel gives the only physical NIC. A MAC would be more precise and would also put this
      # machine's hardware address in a public repository.
      networks."10-eth0" = {
        matchConfig.Name = "eth0";
        networkConfig.DHCP = "ipv4";
        linkConfig.RequiredForOnline = "routable";
      };
    };

    network.ssh = {
      enable = true;

      # NOT 22, and this is the difference between a recovery path that works and one that trains you to ignore a
      # warning. Same host, same port, different key is exactly what ssh reports as REMOTE HOST IDENTIFICATION HAS
      # CHANGED - every single boot, because the initrd and the running system are different hosts as far as
      # `known_hosts` is concerned. A separate port gives each its own entry and neither ever complains.
      port = 2222;

      # A DEDICATED key, never the machine's real host key, and it lives outside the store. `hostKeys` given a
      # string rather than a path routes it through `boot.initrd.secrets`, which the bootloader installer appends
      # at `nixos-rebuild boot` time - so the private key is never world-readable in /nix/store and never in git.
      # It does end up in the initrd, and therefore unencrypted on the ESP: whoever can read that partition can
      # impersonate this initrd, which is how a passphrase gets harvested. That is why it must not be the real
      # host key, and why it is worth knowing rather than glossing.
      #
      # Create it once, on the machine, before the first `nixos-rebuild boot` that carries this:
      #
      #     sudo mkdir -p /etc/secrets/initrd
      #     sudo ssh-keygen -t ed25519 -N "" -f /etc/secrets/initrd/ssh_host_ed25519_key
      #
      # Missing, the bootloader install fails - on the machine, loudly, rather than at evaluation.
      #
      # Rotating it has a trap worth knowing: `boot.initrd.secrets` copies the file without making the initrd
      # depend on its CONTENT, so replacing the key alone leaves the toplevel unchanged and the installed
      # generation is not rebuilt. The old key stays on the ESP. Change something in the configuration too, or
      # rotate into a new generation.
      hostKeys = [ "/etc/secrets/initrd/ssh_host_ed25519_key" ];

      # One source of truth with the running system's, from serverbase's own user definition. The initrd logs in
      # as root, so these become root's authorized keys there.
      authorizedKeys = config.users.users.${config.setup.username}.openssh.authorizedKeys.keys;
    };
  };

  disko.devices.disk.main = {
    device = "/dev/nvme0n1";
    type = "disk";
    preCreateHook = ''
      dd if=/dev/zero of="$device" bs=1M count=16 conv=fsync
    '';
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          type = "EF00";
          size = "512M";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        swap = {
          size = "4G";
          type = "8200";
          content = {
            type = "swap";
            # Encrypted with a key generated fresh at every boot, and never stored anywhere.
            #
            # Swap is a hole straight through any other encryption on this machine. The kernel pages whatever is in
            # RAM out to it - decrypted database rows, session tokens, key material that a service had open - and
            # 4 G of that sits on the same disk in the clear. Encrypting application state while leaving swap
            # readable protects the copy on disk and leaves the copy next to it.
            #
            # A random per-boot key is the right shape here because it costs nothing: no keyslot, no passphrase, no
            # dependency on the key server, and nothing to lose or recover. The only thing it rules out is
            # hibernation, which needs the swap contents to survive a power cycle - and these are servers that never
            # hibernate.
            randomEncryption = true;
          };
        };
        nixos = {
          size = "100%";
          content =
            let
              root = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            in
            if rootEncrypted then
              {
                type = "luks";
                name = "cryptroot";
                # Read only by disko's own format script, so it matters when a VM is installed from the ISO and
                # never on the real machine, which gets here by in-place conversion instead. Write it at the
                # installer shell before running the install - `printf %s test > /tmp/luks_key` - or the format
                # step fails asking for a passphrase nobody is there to type.
                passwordFile = "/tmp/luks_key";
                settings = {
                  allowDiscards = true;
                };
                content = root;
              }
            else
              root;
        };
      };
    };
  };
}
