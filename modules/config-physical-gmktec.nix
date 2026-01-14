{
  modulesPath,
  inputs,
  lib,
  pkgs,
  config,
  ...
}:

{
  imports = [
    # "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
    "${modulesPath}/installer/cd-dvd/iso-image.nix"
    "${modulesPath}/installer/cd-dvd/latest-kernel.nix"
    inputs.nixos-hardware.nixosModules.gmktec-nucbox-g3-plus
  ];

  # EFI booting
  isoImage.makeEfiBootable = true;
  # USB booting
  isoImage.makeUsbBootable = true;
  # Add Memtest86+ to the CD.
  boot.loader.grub.memtest86.enable = true;
  # An installation media cannot tolerate a host config defined file
  # system layout on a fresh machine, before it has been formatted.
  swapDevices = lib.mkImageMediaOverride [ ];
  fileSystems = lib.mkImageMediaOverride config.lib.isoFileSystems;
  # boot.initrd.luks.devices = lib.mkImageMediaOverride { };
  boot.postBootCommands = ''
    for o in $(</proc/cmdline); do
      case "$o" in
        live.nixos.passwd=*)
          set -- $(IFS==; echo $o)
          echo "nixos:$2" | ${pkgs.shadow}/bin/chpasswd
          ;;
      esac
    done
  '';

  boot = {
    # kernelPackages = pkgs.pkgs.linuxPackages_latest; # not necessary, the latest-kernel.nix already uses the latest kernel
    initrd = {
      kernelModules = [
        "usb_storage"
        "uas"
        "sd_mod"
        "xhci_pci"
        "ehci_pci"
      ];
      availableKernelModules = {
        vfat = true;
        ext4 = true;
        fuse = true;
        nls_cp437 = true;
        nls_iso8859_1 = true;
      };
    };
  };
}
