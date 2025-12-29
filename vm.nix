{ config, pkgs, lib, modulesPath, ... }:

{
  imports = [
     "${toString modulesPath}/virtualisation/virtualbox-image.nix"
  ];

  # fileSystems = {
  #   "/" = {
  #     device = "/dev/disk/by-label/nixos";
  #     fsType = "ext4";
  #   };
  # };
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
