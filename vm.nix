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

  boot = {
    kernelParams = [
      "console=ttyS0,115200n8" # this is for the serial console so connections with socat work
    ];
  };
}
