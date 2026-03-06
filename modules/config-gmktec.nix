{ pkgs, lib, ... }:

{
  boot.kernelPackages = pkgs.linuxKernel.packages.linux_hardened; # using hardened kernel, which is not the latest kernel (at the moment)
  setup.docker.extra-daemons = lib.mkDefault [
    {
      name = "kata";
      kata-runtime.enable = true;
      network.disableICC = true;
    }
    { }
  ];
}
