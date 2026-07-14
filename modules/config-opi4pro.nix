{
  pkgs,
  lib,
  config,
  ...
}:

{
  imports = [ ];

  boot = lib.mkMerge [
    {
      loader.systemd-boot.enable = lib.mkDefault false; # using grub and not UEFI
    }
    (lib.mkIf config.setup.isVM {
      kernelPackages = pkgs.linuxPackages_6_6; # use same version as the one we can use on the board, see the physical configuration
    })
  ];
}
