{ pkgs, lib, ... }:

{
  imports = [ ];

  boot = {
    # do not use pkgs.linuxPackages_latest, try to stay as close as possible to the kernel version used in the raspberry pi 4
    # check the version with: nix eval --raw nixpkgs#legacyPackages.aarch64-linux.linuxPackages_rpi4.kernel.version
    kernelPackages = lib.mkDefault pkgs.linuxPackages_6_12;
    loader.systemd-boot.enable = lib.mkDefault false; # using grub and not UEFI
  };
}
