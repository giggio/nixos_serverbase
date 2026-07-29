# Orange Pi 4 Pro - BOOT-ONLY SD image (card replacement, not installation).
#
# The SD card in an installed Orange Pi 4 Pro is not a system disk: the root filesystem lives on the NVMe, and the card only
# carries the boot chain, because the SoC's boot ROM can fetch the first-stage loader from SD/eMMC raw sectors and nowhere else.
# See the header of config-physical-opi4pro-common.nix for the full chain. What the card actually holds is:
#
#   raw sectors  : boot0 @ 8 KiB, boot_package (U-Boot + BL31 + SCP) @ 16400 KiB - no filesystem
#   partition 1  : FAT, label FIRMWARE, starts at 48 MiB, MARKED BOOTABLE - Image, uInitrd, the DTB and boot.scr
#
# That is the whole card. The installer image (setup-opi4pro.nix) additionally puts an ext4 root at partition 2, but that
# partition is the INSTALLER's own root and is dead weight the moment the installation finishes - nothing on the installed
# system ever mounts it.
#
# So replacing a dying/undersized card does NOT require reinstalling: it requires reproducing those two regions. That is what
# this builder does, straight from the FINAL system's own boot artifacts - the same four files, byte for byte, that
# `nixos-rebuild switch` writes to /boot/firmware through installOpi4ProBootloader. The result is ~304 MiB uncompressed
# (48 MiB of bootloader region + a 256 MiB FAT partition) instead of a multi-GB installer, and flashing it destroys nothing:
# the NVMe is never touched.
#
# THE ONE COUPLING TO GET RIGHT: boot.scr bakes `init=<toplevel>/init` - an absolute /nix/store path. The card is therefore
# tied to one specific system generation, and that generation's store path MUST already exist on the NVMe or the board boots
# to a stage-1 panic. Build this image from the same flake revision the machine is currently running (deploy first, then
# build the card), and the paths match by construction. Recovering from a mismatch does not need a rebuild of the card: boot
# an older generation from the U-Boot prompt, or `nixos-rebuild switch` once the system is up and the install hook rewrites
# boot.scr on the card in place.
{
  # Builds a boot-only SD image for one machine variant. Called from mkInstallerPackages in lib.nix for machines that set
  # `imgIsInstaller = true` (i.e. machines whose card carries only the boot chain). Produces a single
  # `<hostName><dev?>boot.img.zst`, matching the naming contract of mkSdCardImage/mkOpi4ProInstallerImage so the Makefile's
  # generic img rule builds it unchanged.
  mkOpi4ProBootImage =
    {
      # nixpkgs for the TARGET architecture (aarch64). Only the image-assembly tools come from here.
      pkgs,
      # The fully evaluated FINAL system (e.g. nixosConfigurations."opi4pronas"). Unlike the installer builder, this one
      # DELIBERATELY references system.build.toplevel: the kernel, DTB and the boot.scr's init= path must be that exact
      # generation's. Only the four boot files are copied into the image; the closure itself stays on the NVMe.
      finalSystem,
      isDev,
    }:
    let
      cfg = finalSystem.config;
      hostName = cfg.setup.hostName;
      toplevel = cfg.system.build.toplevel;
      dtbName = cfg.hardware.deviceTree.name;

      # Both offsets are fixed by the hardware/blob contract, not by us: the boot ROM reads boot0 from 8 KiB and boot0 reads
      # the boot package from 16400 KiB. Identical to flashUboot and to the installer's postBuildCommands.
      boot0OffsetKiB = 8;
      bootPackageOffsetKiB = 16400;

      # The FAT partition must start after the raw bootloader region, which ends around 17.8 MiB. 48 MiB is what the installer
      # image uses (sdImage.firmwarePartitionOffset), and the installed system's fstab finds the partition by LABEL, so keeping
      # the same geometry means a card written by either builder is interchangeable.
      firmwareOffsetMiB = 48;
      firmwareSizeMiB = 256;

      file = "${hostName}${if isDev then "dev" else ""}boot.img.zst";
      img = "${hostName}${if isDev then "dev" else ""}boot.img";
    in
    pkgs.runCommand file
      {
        nativeBuildInputs = with pkgs; [
          util-linux # sfdisk
          dosfstools # mkfs.vfat
          mtools # mcopy, mmd
          zstd
        ];
      }
      /* bash */ ''
        mkdir -p "$out"

        # ---------------------------------------------------------------------------------------------------------------------
        # 1. The FAT firmware partition, built standalone and dd'd into place afterwards (mkfs.vfat cannot format at an offset).
        # ---------------------------------------------------------------------------------------------------------------------
        truncate -s ${toString firmwareSizeMiB}M firmware.img
        # -n FIRMWARE is load-bearing: the installed system mounts /boot/firmware from /dev/disk/by-label/FIRMWARE.
        mkfs.vfat -n FIRMWARE firmware.img

        # These four files are exactly what installOpi4ProBootloader writes on every `nixos-rebuild switch`, taken from the same
        # sources, so a freshly flashed card is indistinguishable from one the running system just updated.
        # Raw aarch64 Image (no uImage wrapper): boot.scr uses `booti`, which takes the kernel unwrapped.
        mcopy -i firmware.img "${toplevel}/kernel" ::Image
        # The initrd, in contrast, IS wrapped in U-Boot's legacy image format - U-Boot needs the size/compression metadata.
        mcopy -i firmware.img "${cfg.system.build.opi4proInitrdUImage}/uInitrd" ::uInitrd
        mmd -i firmware.img ::allwinner
        mcopy -i firmware.img "${toplevel}/dtbs/${dtbName}" "::allwinner/$(basename ${dtbName})"
        # boot.scr is the generation-specific one - see the init= note in this file's header.
        mcopy -i firmware.img "${cfg.system.build.opi4proBootScript}" ::boot.scr

        echo "--- FAT partition contents ---"
        mdir -i firmware.img -/ ::

        # ---------------------------------------------------------------------------------------------------------------------
        # 2. The image itself: MBR label, one bootable FAT partition, and the raw bootloader underneath it.
        # ---------------------------------------------------------------------------------------------------------------------
        truncate -s ${toString (firmwareOffsetMiB + firmwareSizeMiB)}M ${img}

        # MBR, not GPT: vendor U-Boot's distro-boot runs `part list mmc 0 -bootable devplist` and only scans partitions carrying
        # the bootable flag, so partition 1 must be flagged - and it must be the ONLY one, which here is free (there is no
        # second partition to begin with).
        sfdisk ${img} <<EOF
        label: dos
        start=$(( ${toString firmwareOffsetMiB} * 1024 * 1024 / 512 )), size=$(( ${toString firmwareSizeMiB} * 1024 * 1024 / 512 )), type=b, bootable
        EOF

        dd if=firmware.img of=${img} seek=${toString firmwareOffsetMiB} bs=1M conv=notrunc

        # conv=notrunc on both: without it dd would truncate the image at the end of what it just wrote.
        dd if=${cfg.system.build.opi4proUboot}/boot0_sdcard.fex of=${img} seek=${toString boot0OffsetKiB} bs=1k conv=notrunc
        dd if=${cfg.system.build.opi4proUboot}/boot_package.fex of=${img} seek=${toString bootPackageOffsetKiB} bs=1k conv=notrunc

        echo "--- Partition table ---"
        sfdisk --list ${img}

        zstd -T$NIX_BUILD_CORES -o "$out/${file}" ${img}
      '';
}
