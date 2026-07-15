# Orange Pi 4 Pro - the FINAL installed system's physical hardware module.
#
# Root filesystem on the NVMe SSD (managed by disko), boot chain on the SD card (managed by config-physical-opi4pro-common.nix).
# See the header of that file for the full boot-chain and disk-layout documentation.
#
# The SD card is a PERMANENT requirement: the SoC's immutable boot ROM can only fetch the first-stage loader from SD/eMMC raw
# sectors, never from PCIe/NVMe. After installation the card carries only boot artifacts (raw bootloader sectors plus the FAT
# FIRMWARE partition holding Image, uInitrd, the DTB and boot.scr); everything else lives on the NVMe.
#
# The `disko.devices` layout below is used twice:
#   - at INSTALL time, the installer image (see setup-opi4pro.nix) runs this configuration's
#     `config.system.build.destroyFormatMount` to wipe, partition, format and mount the NVMe under /mnt;
#   - at RUN time, disko translates the same layout into this system's fileSystems."/" definition, so stage 1 mounts the root
#     from the NVMe (the initrd's `nvme` module is guaranteed by the common module).
{ inputs, ... }:

{
  imports = [
    inputs.disko.nixosModules.disko
    ./config-physical-opi4pro-common.nix
  ];

  disko.devices.disk.main = {
    # The board has exactly one M.2 slot, so this device name is stable by construction - same reasoning as the GMKTec layout in
    # config-physical-gmktec.nix.
    device = "/dev/nvme0n1";
    type = "disk";
    content = {
      type = "gpt";
      partitions = {
        # No ESP: this board boots via the Allwinner chain on the SD card, not UEFI. No swap: zram is enough for this workload,
        # and encryption is deliberately out of scope for now (no TPM on this board; boots must be unattended).
        nixos = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
            # Label the filesystem for humans and recovery documentation; the generated fstab mounts by partition device.
            extraArgs = [
              "-L"
              "NIXOS_ROOT"
            ];
          };
        };
      };
    };
  };
}
