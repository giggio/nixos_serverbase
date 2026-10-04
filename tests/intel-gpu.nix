{
  pkgs,
  lib,
  nixosConfigurations,
  ...
}:

# Covers modules/serverbase/hardware/intel-gpu.nix: that enabling `setup.intelGpu` on the physical machine actually
# turns the graphics stack on - the piece nixos-hardware stages the Intel packages for but never enables - and that
# the virtualboot VM, which imports the same physical module, is left alone.
#
# A derivation rather than a nixosTest: the assertion is a property of the evaluated configuration, and the Intel
# iGPU the module is about does not exist inside qemu. Booting would prove nothing that a build of this does not.
let
  physical = nixosConfigurations.gmktec1.config;
  vm = nixosConfigurations.gmktec1vmboot.config;

  # The drivers nixos-hardware's common/gpu/intel adds to extraPackages. Asserting them here is the point: with
  # graphics.enable off they sit in the list and never reach /run/opengl-driver, which is the bug this module fixes.
  drivers = [
    "intel-media-driver"
    "intel-compute-runtime"
    "vpl-gpu-rt"
  ];
  staged = map (p: p.pname) physical.hardware.graphics.extraPackages;
  driverList = lib.concatStringsSep " " staged;
in
pkgs.runCommand "intel-gpu-assertions" { } ''
  echo "gmktec1 extraPackages: ${driverList}"

  echo "gmktec1 enables the graphics stack and the iGPU firmware"
  test "${lib.boolToString physical.setup.intelGpu.enable}" = "true"
  test "${lib.boolToString physical.hardware.graphics.enable}" = "true"
  test "${lib.boolToString physical.hardware.enableRedistributableFirmware}" = "true"

  echo "the driver packages nixos-hardware stages are in place"
  ${lib.concatMapStrings (d: ''
    if ! echo "${driverList}" | grep -qw "${d}"; then
      echo "FAIL: extraPackages are missing ${d}: ${driverList}"
      exit 1
    fi
  '') drivers}

  echo "the virtualboot VM, which imports the same physical module, is left alone"
  ${
    if vm.setup.intelGpu.enable then
      ''
        echo "FAIL: virtualboot enabled the Intel GPU stack"
        exit 1
      ''
    else
      ''echo "  virtualboot: off"''
  }

  touch $out
''
