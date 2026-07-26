{
  pkgs,
  lib,
  machines,
  nixosConfigurations,
  ...
}:

# Covers the machine-combination matrix in modules/lib.nix: mkNixosMachineCombinations, mkNixosModulesCombinations and
# mkNixosModuleName, checked through what they actually produce - the flake's `nixosConfigurations`. That output is the
# contract the Makefile, the installer packages and every other check are written against, so the expected set is derived
# here a second time, straight from the machine list and the rules the comments in lib.nix state, rather than being
# copied from the current output. A rule that silently stops applying (an x86_64 machine gaining an emulated aarch64 VM,
# a machine without an ISO gaining vmboot variants) then shows up as a name that should not exist.
#
# A derivation rather than a nixosTest: there is nothing to boot, and asserting over attribute *names* never forces a
# machine to evaluate, so the whole check finishes in seconds.
let
  # the same transformation mkNixosModuleName applies to a system before it goes into a name
  archOf = system: builtins.replaceStrings [ "_" ] [ "" ] (lib.strings.removeSuffix "-linux" system);

  expectedNamesFor =
    machine:
    let
      arch = archOf machine.defaultArch;
      # a machine is built for its own architecture, and additionally emulated on x86_64 as a VM, because x86_64 is the
      # only architecture VMs are ever driven from
      vmArches = lib.lists.unique [
        arch
        (archOf "x86_64")
      ];
      withDev =
        names:
        lib.concatMap (name: [
          name
          (builtins.replaceStrings [ machine.name ] [ "${machine.name}dev" ] name)
        ]) names;
    in
    withDev (
      [ "${machine.name}${arch}" ]
      ++ (map (vmArch: "${machine.name}${vmArch}vm") vmArches)
      ++ (lib.optionals machine.supportsIso (map (vmArch: "${machine.name}${vmArch}vmboot") vmArches))
      # the short aliases mkNixosConfigurations adds on top of the combinations, so that `nixos-rebuild --flake .#pi4`
      # works without spelling out the architecture
      ++ [ machine.name ]
      ++ (lib.optionals machine.supportsIso [ "${machine.name}vmboot" ])
    );

  expectedNames = lib.sort lib.lessThan (lib.concatMap expectedNamesFor machines);
  actualNames = lib.sort lib.lessThan (builtins.attrNames nixosConfigurations);

  # One configuration per machine is evaluated for real, to prove the name is not just present but describes what the
  # configuration turned out to be. The dev VM is the one every check and the Makefile reach for, so it is the one worth
  # holding to its promises.
  devVmOf = machine: nixosConfigurations."${machine.name}dev${archOf machine.defaultArch}vm";

  unitTests = lib.runTests (
    {
      testEveryExpectedConfigurationExistsAndNoOthers = {
        expr = actualNames;
        expected = expectedNames;
      };
    }
    // lib.listToAttrs (
      map (machine: {
        name = "testTheDevVmOf${machine.name}IsADevVm";
        value =
          let
            config = (devVmOf machine).config;
          in
          {
            expr = {
              inherit (config.setup)
                isDev
                isVM
                isTest
                hostName
                ;
              derivedHostName = config.setup.derivedHostName;
              system = config.nixpkgs.hostPlatform.system;
            };
            expected = {
              isDev = true;
              isVM = true;
              isTest = false;
              hostName = machine.name;
              # dev and VM both leave their mark on the name the machine answers to
              derivedHostName = "${machine.name}devvm";
              system = "${machine.defaultArch}-linux";
            };
          };
      }) machines
    )
  );
in
pkgs.runCommand "flake-matrix"
  {
    failures = builtins.toJSON unitTests;
  }
  ''
    if [ "$failures" != "[]" ]; then
      echo "flake matrix unit tests failed:" >&2
      echo "$failures" >&2
      exit 1
    fi

    touch $out
  ''
