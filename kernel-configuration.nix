{ pkgs, lib, ... }:

{
  boot = {
    kernelPackages = pkgs.linuxPackages_latest; # todo: evaluate if we should use the vendored kernel: pkgs.linuxKernel.packages.linux_rpi4 or pkgs.linuxPackages_rpi4
    supportedFilesystems.zfs = lib.mkForce false; # todo: remove this when zfs is supported
    kernelModules = [ "bcm2835-v4l2" ]; # originally missing, as we are not using the vendored kernel
    kernelParams = lib.mkForce [
      # removing console=ttyAMA0,115200n8, which breaks Pi4's Bluetooth
      "console=ttyS0,115200n8"
      "console=tty0"
      "loglevel=7"
      "lsm=landlock,yama,bpf"
    ];
    initrd.kernelModules = [ "usb_storage" "uas" "sd_mod" "xhci_pci" "ehci_pci" ];
    initrd.availableKernelModules = [ "vfat" "ext4" "fuse" "nls_cp437" "nls_iso8859_1" ];
  };
}
