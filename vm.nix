{ config, pkgs, lib, ... }:

{
  imports = [
  ];

  # fileSystems = {
    # "/" = {
    #   device = "/dev/sda2";
    #   fsType = "ext4";
    # };

    # "/boot" = {
    #   # device = "/dev/sda1";
    #   device = "/dev/disk/by-label/boot";
    #   fsType = "vfat";
    #   # options = [ "fmask=0022" "dmask=0022" ];
    # };
  # };

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  virtualisation = {
    virtualbox.guest.enable = true;
    diskSize = 20 * 1024;
  };
}
