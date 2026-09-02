{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

# THIS MACHINE'S ROOT IS A LUKS CONTAINER, since 2026-09-01. Everything below describes that; nothing below
# creates it. Until 2026-09-02 a `rootEncrypted` binding here selected between this layout and the plain-ext4 one
# the machine had before, which was how the migration was carried; the migration is over and the alternative went
# with it. See PLAN_ENCRYPTION.md step 8d for why, and step 8a - or git history for this file - for the layout it
# replaced.
#
# What disko does here is generate `fileSystems."/"` and `boot.initrd.luks.devices`; it only PARTITIONS when its
# own format script is run, which on gmktec1 has never happened. The disk got here by
# `cryptsetup reencrypt --encrypt --reduce-device-size 32M` from a live USB, in place, on
# /dev/disk/by-partlabel/disk-main-nixos - the one step in the encryption plan with no rollback except a restore.
#
# Only the MAPPER NAME below has to agree with anything, and it agrees with itself: the initrd names the mapping
# when it unlocks, so `cryptroot` here produces /dev/mapper/cryptroot there whatever the on-disk container is
# called. There is deliberately no `--label`, because nothing reads one and a value that must match but is never
# checked is a trap rather than a safeguard.
{
  imports = [
    inputs.nixos-hardware.nixosModules.gmktec-nucbox-g3-plus
    inputs.disko.nixosModules.disko
    # Lanzaboote, for the only machine here with Secure Boot firmware at all - the ARM boards have none. It cannot
    # go in the shared service set: `lib.mkIf false` still requires the option it defines to EXIST, so with
    # `setup.secureBoot.enable = false` the definition of `boot.lanzaboote` is deferred but still placed, and pi4
    # and opi4pronas failed to evaluate with `The option boot.lanzaboote does not exist`.
    #
    # And it cannot be imported from the service module either, because `imports` cannot depend on `config` and a
    # test node receives `inputs` through `_module.args` rather than specialArgs: doing it there is an infinite
    # recursion.
    #
    # So the two travel together, here, and the OPTIONS they configure travel separately - in
    # ./config-gmktec.nix, which every variant of this machine imports including `test`. A machine's service
    # modules set `setup.secureBoot`, and they must not depend on which hardware variant they are evaluated
    # under. See serverbase/services/secureboot/options.nix.
    #
    # None of it does anything until `setup.secureBoot.enable` is set. Measured, not assumed: with the flag off
    # the systemd units, /etc entries, sops secrets, systemPackages and boot loader settings are identical either
    # way.
    inputs.lanzaboote.nixosModules.lanzaboote
    ./serverbase/services/secureboot/secureboot.nix
  ];

  boot.loader.systemd-boot = {
    enable = true; # using UEFI and not GRUB

    # Set BEFORE the root is encrypted and the boot chain is signed, not after. The default is `null`, meaning
    # unlimited, and this ESP is a 512 M partition. Today it holds a kernel and an initrd per generation; under
    # lanzaboote each generation instead becomes one UKI carrying both, and the initrd closure alone is 35.9 MiB,
    # so call it 50 M a generation. Unlimited then fills the partition, and a full ESP makes the bootloader install
    # fail - on a machine whose root is encrypted and whose boot chain is signed, which is the worst place to meet
    # a disk-space problem. The partition cannot be grown without repartitioning, so the limit is the fix.
    #
    # Three rather than five: five is roughly where the ESP *fills*, and a limit set at the fill point leaves no
    # headroom for a UKI that grows. Three is ~150 M of 512 M and still leaves two generations to roll back to,
    # which is what actually matters on a machine that can fail to boot for signing reasons.
    #
    # It costs rollback depth: generations past the limit are dropped from the ESP on the next switch. They remain
    # in the store and in `nix profile history`, they are simply no longer offered by the boot menu.
    configurationLimit = 3;

    # No command-line editing at the boot menu. Off because of what step 8c does, not as general tidying: once the
    # TPM unlocks the root automatically, a thief who boots the machine has a decrypted filesystem underneath a
    # login prompt, and an editable command line turns that prompt into `init=/bin/sh` and a root shell. That
    # single line would hand back everything the encryption was for.
    #
    # It costs less than it looks, because it does not disable the menu - only the `e` key. Selecting an older
    # generation still works, and generations are self-contained: a bad new one cannot break the ones already
    # installed, since each carries its own kernel, initrd and command line. So the ordinary recovery - boot the
    # previous configuration - is untouched. Note that `configurationLimit` above is what bounds how far back that
    # goes, which is the real reason the two belong together.
    #
    # What it does cost is the rescue trick of appending a parameter by hand - `systemd.unit=rescue.target`,
    # `boot.shell_on_fail`. The replacement for that is the live USB, which step 8a needs anyway and which reaches
    # the same place through `nixos-enter`. Worth knowing before it is wanted rather than at the time.
    editor = false;
  };

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
  # plugged into the box. The mechanism, the port choice and what the host key costs are all in
  # serverbase/services/initrd-ssh.nix; what belongs here is why THIS machine needs it and which driver it takes.
  #
  # It is not a convenience. This machine sets no `console=` kernel parameter, so the initrd passphrase prompt goes
  # to tty0 - the HDMI console - and the CH340 bridge above is a getty started by a udev rule once userspace is up,
  # far too late to type a passphrase into. Without this, every boot between the conversion and the TPM enrolment
  # needs someone standing at the machine with a monitor.
  setup.initrdSsh = {
    enable = true;
    # The Intel I226-V on this board - read off the machine 2026-08-25, `eth0` -> `igc`, rather than guessed.
    kernelModules = [ "igc" ];
  };

  # SWAP, as a file on the root rather than a partition of its own.
  #
  # It was a partition with `randomEncryption` - a fresh key every boot, never stored. That was the right shape
  # while the root was plain ext4, because swap is otherwise a hole straight through every other protection: the
  # kernel pages out decrypted database rows, session tokens and key material a service had open, and that lands
  # on the disk in the clear. What changed is that the root is now a LUKS container, so a file living on it is
  # already inside the same encryption, unlocked by the same key, with one less dm-crypt layer to configure and
  # nothing extra to go wrong at boot.
  #
  # Same 4 G as the partition it replaces, and it is really used - 2 G of it on a 7.5 G machine. It rules out
  # hibernation exactly as `randomEncryption` did, which costs these servers nothing.
  #
  # NixOS creates the file itself when it is missing, so there is nothing to do by hand after a reinstall.
  swapDevices = [
    {
      device = "/swapfile";
      size = 4096;
    }
  ];

  disko.devices.disk.main = {
    device = "/dev/nvme0n1";
    type = "disk";
    preCreateHook = ''
      dd if=/dev/zero of="$device" bs=1M count=16 conv=fsync
    '';
    content = {
      type = "gpt";
      partitions = {
        # 4.5 G rather than the 512 M this started as, and the extra 4 G is the swap partition that used to sit
        # between this and the data. Under lanzaboote a generation stops being a kernel plus an initrd and becomes
        # one UKI carrying both, so the ESP is what bounds how far back the boot menu reaches - at roughly 50 M a
        # generation, 512 M was about ten and most of it was already spoken for at 46% full.
        #
        # It could only grow this way. The ESP is the first partition and the data partition is the last, so
        # anything taken from the end would have meant moving 472 G; anything taken from swap-as-a-partition would
        # have meant cutting swap on a box with 7.5 G of RAM that had 2 G of swap in use. Removing the partition
        # and moving swap into a file on the encrypted root costs neither - see swapDevices below.
        ESP = {
          type = "EF00";
          size = "4608M";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };

        nixos = {
          size = "100%";
          content = {
            type = "luks";
            name = "cryptroot";
            # Read only by disko's own format script, so it matters when a machine is installed from the ISO and
            # never on the real gmktec1, which got here by in-place conversion instead.
            #
            # There is no shell to write this file from: the ISO's unattended-install service conflicts with both
            # gettys, so the install runs on a console with nobody on it. The ISO puts the file here itself before
            # calling disko - from removable media, from a well-known value on a dev image, or by asking - see
            # scripts/provision-luks-key.sh. Both ends read the path off the option so they cannot drift apart.
            passwordFile = config.setup.luksKeyFile;
            settings = {
              allowDiscards = true;
            };
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
            };
          };
        };
      };
    };
  };
}
