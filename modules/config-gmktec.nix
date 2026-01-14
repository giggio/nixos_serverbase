{ modulesPath, ... }:

{
  imports = [
    "${modulesPath}/installer/cd-dvd/latest-kernel.nix"
  ];
  # boot.kernelPackages = pkgs.pkgs.linuxPackages_latest; # not necessary, the latest-kernel.nix already uses the latest kernel
}
