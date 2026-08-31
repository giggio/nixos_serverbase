{ pkgs, lib, ... }:

{
  # Having Secure Boot firmware is a property of THIS MACHINE rather than of one of its variants, so the options
  # that describe it belong here, where every variant sees them - physical, virtual, virtualboot and `test`.
  # gmktec1's service modules set `setup.secureBoot`, and a service module must not depend on which hardware
  # variant it is evaluated under; with the options only on the physical variant, every superproject check that
  # boots gmktec1 died with `The option nodes.machine.setup.secureBoot does not exist`.
  #
  # Only the OPTIONS, though. The half that configures `boot.lanzaboote` cannot come along, because `lib.mkIf
  # false` still requires the option it defines to exist and a test node has no lanzaboote - and lanzaboote's own
  # module cannot be imported from here either, since `imports = [ inputs.lanzaboote... ]` on a path a test node
  # evaluates is an infinite recursion (`inputs` arrives through `_module.args`, and `imports` cannot depend on
  # `config`). Both halves live in config-physical-gmktec.nix. See secureboot/options.nix.
  imports = [ ./serverbase/services/secureboot/options.nix ];

  boot.kernelPackages = pkgs.linuxPackages_latest;
  setup.docker.extra-daemons = lib.mkDefault {
    kata = {
      kata-runtime.enable = true;
      network.disableICC.enable = true;
      network.subnetOctet = 39;
    };
    other = {
      network.subnetOctet = 40;
    };
  };
}
