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
    # Anywhere the board itself is not running - a VM or a test - the kernel is a hand-picked approximation of the one it
    # really uses. Tests have to make the same approximation as the VMs, otherwise they would be proving the behaviour of
    # a kernel this machine never runs.
    (lib.mkIf (config.setup.isVM || config.setup.isTest) {
      kernelPackages = pkgs.linuxPackages_6_6; # use same version as the one we can use on the board, see the physical configuration
    })
  ];
}
