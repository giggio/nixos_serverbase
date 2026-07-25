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
      # do not use pkgs.linuxPackages_latest, try to stay as close as possible to the kernel version used in the raspberry pi 4
      # check the version with: nix eval --raw nixpkgs#legacyPackages.aarch64-linux.linuxPackages_rpi4.kernel.version
      kernelPackages = lib.mkDefault pkgs.linuxPackages_6_12;
    })
  ];
}
