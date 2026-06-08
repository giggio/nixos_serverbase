{ pkgs, lib, ... }:

{
  boot.kernelPackages = pkgs.linuxPackages_latest;
  setup.docker.extra-daemons = lib.mkDefault {
    kata = {
      kata-runtime.enable = true;
      network.disableICC.enable = true;
    };
    other = { };
  };
}
