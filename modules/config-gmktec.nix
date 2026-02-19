{ pkgs, ... }:

{
  boot.kernelPackages = pkgs.linuxKernel.packages.linux_hardened; # using hardened kernel, which is not the latest kernel (at the moment)
}
