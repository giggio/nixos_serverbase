{ config, pkgs, lib, modulesPath, ... }:

{
  imports = [
    "${toString modulesPath}/virtualisation/virtualbox-image.nix"
  ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  virtualisation = {
    virtualbox.guest.enable = true;
    diskSize = 20 * 1024;
  };
}
