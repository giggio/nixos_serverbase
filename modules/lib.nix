{
  serverbaseModules,
  lib,
  inputs,
}:
# The Orange Pi 4 Pro image builders live in their own files (the mechanism is very board-specific), and are merged into this
# lib so they are reachable as serverbaseModules.lib.mkOpi4Pro{Installer,Boot}Image from mkInstallerPackages below.
(import ./setup-opi4pro.nix { inherit lib inputs; })
// (import ./setup-opi4pro-boot-image.nix)
// (import ./test-secrets.nix { inherit lib; })
// {
  mkNixosConfigurations =
    machines:
    let
      nixosConfigurations =
        lib.lists.foldr (newConfig: configAccumulator: configAccumulator // newConfig) { }
          (
            (map (
              machine:
              (
                let
                  arch = builtins.replaceStrings [ "_" ] [ "" ] machine.defaultArch;
                in
                # The architecture-free aliases. They exist so a name can be typed - by a person, and by
                # `nixos-rebuild` inside a running machine, which derives the flake attribute from the hostname.
                #
                # `setup.derivedHostName` is `<name><dev><vm>` with NO architecture in it, so every alias below has
                # to match that shape exactly or the machine cannot rebuild itself. The `vm` pair was missing, and
                # the way it failed was worse than an error: `nixos-rebuild` inside a plain dev VM reported
                # `does not provide attribute 'nixosConfigurations."gmktec1devvm"'` and helpfully suggested
                # `gmktec1dev` - which is the PHYSICAL configuration, disko layout and all. Taking that suggestion
                # inside a VM is not a typo, it is switching the machine to a different disk layout.
                {
                  "${machine.name}" = nixosConfigurations."${machine.name}${arch}";
                  "${machine.name}dev" = nixosConfigurations."${machine.name}dev${arch}";
                  "${machine.name}vm" = nixosConfigurations."${machine.name}${arch}vm";
                  "${machine.name}devvm" = nixosConfigurations."${machine.name}dev${arch}vm";
                }
                # vmboot only exists for machines that produce an ISO, since that variant is installed from one.
                // lib.attrsets.optionalAttrs machine.supportsIso {
                  "${machine.name}vmboot" = nixosConfigurations."${machine.name}${arch}vmboot";
                  "${machine.name}devvmboot" = nixosConfigurations."${machine.name}dev${arch}vmboot";
                }
              )
            ) machines)
            ++ (map (config: {
              "${config.name}" = config.configuration;
            }) (serverbaseModules.lib.mkNixosModulesCombinations machines))
          );
    in
    builtins.mapAttrs (_: module: lib.nixosSystem module) nixosConfigurations;

  # Builds the flake `checks` from a set of test files. Each test file is a function
  #   { pkgs, lib, inputs, machines, testNodes, ... }: <nixosTest definition | derivation>
  # where `testNodes.base` and `testNodes.machine <name>` are NixOS modules that reproduce, respectively, the plain serverbase
  # configuration and a real machine from the flake's machine list, and `testNodes.vmConfigurationOf <name>` is the evaluated
  # configuration of the VM that machine is driven as. Building nodes from the actual machine definition is the point: a
  # service test then exercises the same modules the machine really boots with, instead of a hand-written copy that drifts.
  mkChecks =
    {
      pkgs,
      machines,
      nixosConfigurations,
      tests,
    }:
    let
      findMachine =
        name:
        lib.lists.findFirst (
          m: m.name == name
        ) (throw "mkChecks: there is no machine named '${name}' in the flake's machine list") machines;
      # The tests must not depend on the caller's nixpkgs configuration, so rebuild pkgs with a known-empty config.
      system = pkgs.stdenv.hostPlatform.system;
      testPkgs = import inputs.nixpkgs {
        inherit system;
        config.allowUnfree = false;
      };
      base =
        { lib, ... }:
        {
          imports = serverbaseModules.default;
          _module.args = {
            inherit inputs;
            helpers = import ./helpers { inherit lib; };
            pkgs-unstable = inputs.nixpkgs-unstable.legacyPackages.${system};
          };
          nixpkgs.pkgs = lib.mkForce testPkgs;
          nixpkgs.config = lib.mkForce { };
          setup = {
            environment = "test";
            # The clone units want the network and credentials a test sandbox does not have, and leaving them on would
            # make every other test's `systemctl --failed` assertion depend on how far their retries had got. The test
            # that is actually about them (tests/clone-config.nix) turns them back on against a local repository.
            vimFiles.enable = lib.mkDefault false;
            nixosConfig = {
              enable = lib.mkDefault false;
              useCredentials = false;
            };
          };
        };
      machine =
        name:
        let
          theMachine = findMachine name;
        in
        {
          imports = [
            base
            theMachine.hardwareModule.test
            { setup.hostName = name; }
          ]
          ++ theMachine.modules;
        };
      # The configuration of the VM this machine is actually driven as on this system - the one the Makefile builds as
      # `<machine><host arch>vm`. A test node approximates the board the same way that VM does (see the kernel choice in
      # config-pi4.nix and config-opi4pro.nix), so a test can hold itself to what the VM resolved to rather than
      # restating it and letting the two drift apart.
      vmConfigurationOf =
        name:
        nixosConfigurations.${
          serverbaseModules.lib.mkNixosModuleName {
            machine = findMachine name;
            isDev = true;
            isVM = true;
            inherit system;
          }
        }.config;
      # Sugar over mkFakeSecrets for a node under test: the module list is evaluated a second time on its own, purely
      # to ask what secrets it declared. That extra evaluation is the whole cost, and it is the only way to stay
      # non-recursive - a module that both reads and defines `config.sops.secrets` cannot be evaluated at all.
      withFakeSecrets =
        {
          modules,
          values ? { },
        }:
        let
          probed =
            (inputs.nixpkgs.lib.nixosSystem {
              # qemu-vm.nix comes along because the test driver brings it too: a node is free to use
              # `virtualisation.fileSystems`, and a probe without that option would fail to evaluate the very
              # modules it exists to inspect
              modules = modules ++ [ "${inputs.nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix" ];
            }).config.sops.secrets;
        in
        modules
        ++ [
          (serverbaseModules.lib.mkFakeSecrets {
            names = builtins.attrNames probed;
            # Asked here rather than inside mkFakeSecrets, for the same reason the names are: a module cannot read
            # `sops.secrets` while defining it. What it decides is whether the fixture has to order its key
            # installation before `setupSecretsForUsers` as well - a script that only exists when something asks
            # for it, and that runs before the users are created rather than with the rest of the secrets.
            hasUserSecrets = builtins.any (secret: secret.neededForUsers) (builtins.attrValues probed);
            inherit values;
          })
        ];
      testNodes = {
        inherit
          base
          machine
          vmConfigurationOf
          withFakeSecrets
          ;
        fakeSecrets = serverbaseModules.lib.mkFakeSecrets;
      };
    in
    builtins.mapAttrs (
      _: test:
      let
        definition = import test {
          inherit
            pkgs
            lib
            inputs
            machines
            nixosConfigurations
            testNodes
            ;
        };
      in
      # A test file yields either a nixosTest definition or a derivation to build directly. Checks over pure functions
      # and over what a package ships have no machine to boot, and as derivations they finish in seconds instead of
      # minutes.
      if lib.isDerivation definition then definition else pkgs.testers.nixosTest definition
    ) tests;

  mkNixosMachineCombinations =
    machines:
    let
      combinations =
        builtins.filter
          (
            combination:
            let
              # A VM variant exists so a machine can be booted on a workstation: natively on its own architecture, and
              # emulated on x86_64, the only architecture VMs are ever driven from (the Makefile always builds
              # `<machine><host arch>vm`). That is what makes the aarch64 boards testable from an x86_64 PC. The inverse -
              # an x86_64 machine emulated as aarch64 - has no use, and would force every service package the machine pulls
              # in to support aarch64.
              vmArchitectures = lib.lists.unique [
                combination.machine.defaultArch
                "x86_64"
              ];
            in
            (
              if combination.isVM then
                builtins.elem combination.system vmArchitectures
              else
                combination.machine.defaultArch == combination.system
            )
            # the vmboot variant only exists to boot an ISO installation inside a VM (see mkIsoPackage), so only machines that
            # produce an ISO define hardwareModule.virtualboot
            && (!combination.isVMBoot || combination.machine.supportsIso)
          )
          (
            lib.lists.flatten (
              map (
                machine:
                map
                  (
                    isVM:
                    map
                      (
                        isDev:
                        map
                          (system: {
                            inherit
                              machine
                              isDev
                              system
                              ;
                            isVM = isVM > 0;
                            isVMBoot = isVM == 2;
                          })
                          [
                            "x86_64"
                            "aarch64"
                          ]
                      )
                      [
                        false
                        true
                      ]
                  )
                  [
                    0
                    1
                    2
                  ]
              ) machines
            )
          );
    in
    combinations;

  mkNixosModulesCombinations =
    machines:
    let
      combinations = serverbaseModules.lib.mkNixosMachineCombinations machines;
    in
    map (
      combination:
      let
        name = serverbaseModules.lib.mkNixosModuleName combination;
        suffixedSystem =
          if lib.strings.hasSuffix "-linux" combination.system then
            combination.system
          else
            "${combination.system}-linux";
      in
      {
        inherit name;
        system = suffixedSystem;
        configuration = {
          specialArgs = {
            inherit inputs;
            helpers = import ./helpers { inherit lib; };
            pkgs-unstable = inputs.nixpkgs-unstable.legacyPackages.${suffixedSystem};
          }
          // (if combination.machine ? specialArgs then combination.machine.specialArgs else { });
          system = suffixedSystem;
          modules =
            serverbaseModules.default
            ++ [
              (
                if combination.isVMBoot then
                  combination.machine.hardwareModule.virtualboot
                else if combination.isVM then
                  combination.machine.hardwareModule.virtual
                else
                  combination.machine.hardwareModule.physical
              )
              {
                nixpkgs.hostPlatform = suffixedSystem;
                setup.hostName = combination.machine.name;
                setup.vm.memorySize = lib.mkIf (
                  combination.machine ? vmMemorySize
                ) combination.machine.vmMemorySize;
                setup.vm.diskSize = lib.mkIf (combination.machine ? vmDiskSize) combination.machine.vmDiskSize;
                setup.vm.useEFIBoot =
                  if (combination.machine ? useEFIBoot) then combination.machine.useEFIBoot else false;
                setup.vm.extraDisks = lib.mkIf (combination.machine ? extraDisks) combination.machine.extraDisks;
              }
              (lib.attrsets.optionalAttrs combination.isDev { config.setup.environment = "dev"; })
            ]
            ++ combination.machine.modules;
        };
      }
    ) combinations;

  mkNixosModuleName =
    {
      machine,
      isDev ? false,
      isVM ? false,
      isVMBoot ? false,
      system,
      ...
    }:
    "${machine.name}${if isDev then "dev" else ""}${
      builtins.replaceStrings [ "_" ] [ "" ] (lib.strings.removeSuffix "-linux" system)
    }${if isVM then "vm${if isVMBoot then "boot" else ""}" else ""}";

  mkInstallerPackages =
    {
      nixosConfigurations,
      machines,
    }:
    let
      combinations = serverbaseModules.lib.mkNixosMachineCombinations machines;
      nixosModules = serverbaseModules.lib.mkNixosModulesCombinations machines;
      evalConfig = import "${inputs.nixpkgs}/nixos/lib/eval-config.nix";
      imageSupportingMachines = builtins.filter (machine: machine.supportsImg) machines;
      installerPackages =
        lib.lists.foldr (packageAccumulator: newPackage: packageAccumulator // newPackage) { } (
          map (
            combination:
            lib.attrsets.optionalAttrs (combination.isVM && !combination.isVMBoot) {
              # machine isVM isDev system
              "${serverbaseModules.lib.mkNixosModuleName combination}" = serverbaseModules.lib.mkVmImage {
                pkgs = import inputs.nixpkgs { system = "${combination.system}-linux"; };
                nixos-system = nixosConfigurations."${serverbaseModules.lib.mkNixosModuleName combination}";
                isDev = combination.isDev;
              };
            }
            // lib.attrsets.optionalAttrs (combination.machine.supportsIso && combination.isVM == false) {
              "${serverbaseModules.lib.mkNixosModuleName combination}_iso" =
                let
                  configName = serverbaseModules.lib.mkNixosModuleName combination;
                  theConfiguration = lib.lists.findFirst (
                    module: module.name == configName
                  ) "unexpected module name" nixosModules;
                  vmBootConfiguration = lib.lists.findFirst (
                    module: module.name == "${configName}vmboot"
                  ) "unexpected module name" nixosModules;
                in
                serverbaseModules.lib.mkIsoPackage {
                  pkgs = import inputs.nixpkgs { system = theConfiguration.system; };
                  isDev = combination.isDev;
                  isVM = combination.isVM;
                  installedSystem = evalConfig theConfiguration.configuration;
                  installedSystemVMBoot = evalConfig vmBootConfiguration.configuration;
                };
            }
          ) combinations
        )
        // lib.foldr (machine_accumulator: new_machine: machine_accumulator // new_machine) { } (
          map (
            machine:
            let
              # Two kinds of _img package share the same name contract (<name>.img.zst / <name>dev.img.zst, so the Makefile's
              # img rule works unchanged for both):
              #   - default: a full-system SD image - the whole system runs from the card (e.g. pi4);
              #   - machine.imgIsInstaller = true: a lean UNATTENDED INSTALLER SD image - it boots the board, wipes the NVMe
              #     with the final system's disko config, and installs the final system onto it from the flake, pulling the
              #     pre-built closure from the attic cache (e.g. opi4pro). See modules/setup-opi4pro.nix.
              # Installer machines additionally get a third, <name>boot_img: a BOOT-ONLY card image for replacing a card under
              # an already-installed system, which reinstalls nothing. See modules/setup-opi4pro-boot-image.nix.
              mkImg =
                isDev:
                let
                  configName = "${machine.name}${if isDev then "dev" else ""}";
                in
                if (machine.imgIsInstaller or false) then
                  serverbaseModules.lib.mkOpi4ProInstallerImage {
                    pkgs = import inputs.nixpkgs { system = "${machine.defaultArch}-linux"; };
                    finalSystem = nixosConfigurations."${configName}";
                    flakeAttr = configName;
                    inherit isDev;
                  }
                else
                  serverbaseModules.lib.mkSdCardImage {
                    pkgs = import inputs.nixpkgs { system = "${machine.defaultArch}-linux"; };
                    nixos-system = nixosConfigurations."${configName}";
                    inherit isDev;
                  };
              mkBootImg =
                isDev:
                serverbaseModules.lib.mkOpi4ProBootImage {
                  pkgs = import inputs.nixpkgs { system = "${machine.defaultArch}-linux"; };
                  finalSystem = nixosConfigurations."${machine.name}${if isDev then "dev" else ""}";
                  inherit isDev;
                };
            in
            {
              "${machine.name}_img" = mkImg false;
              "${machine.name}dev_img" = mkImg true;
            }
            // lib.attrsets.optionalAttrs (machine.imgIsInstaller or false) {
              "${machine.name}boot_img" = mkBootImg false;
              "${machine.name}devboot_img" = mkBootImg true;
            }
          ) imageSupportingMachines
        );
    in
    installerPackages
    // lib.foldr (machine_accumulator: new_machine: machine_accumulator // new_machine) { } (
      map (machine: {
        "${machine.name}_iso" =
          installerPackages."${
            serverbaseModules.lib.mkNixosModuleName {
              inherit machine;
              isDev = false;
              isVM = false;
              system = machine.defaultArch;
            }
          }_iso";
        "${machine.name}dev_iso" =
          installerPackages."${
            serverbaseModules.lib.mkNixosModuleName {
              inherit machine;
              isDev = true;
              isVM = false;
              system = machine.defaultArch;
            }
          }_iso";
      }) (lib.filter (machine: machine.supportsIso) machines)
    );

  mkIsoPackage =
    {
      installedSystem,
      installedSystemVMBoot,
      pkgs,
      isVM,
      isDev,
    }:
    let
      cfg = installedSystem.config;
      cfgVMBoot = installedSystemVMBoot.config;

      # Only when the system being installed actually has an encrypted root. `boot.initrd.luks.devices` is what
      # disko generates from a `type = "luks"` partition, so it is true exactly when the format step is going to
      # want a passphrase - and it costs nothing to check both variants, since a VM installs cfgVMBoot and
      # hardware installs cfg.
      needsLuksKey = cfg.boot.initrd.luks.devices != { } || cfgVMBoot.boot.initrd.luks.devices != { };

      # The initrd sshd's host key, which `boot.initrd.secrets` copies into the initrd when the BOOTLOADER is
      # installed - so it has to exist in the target before `nixos-install` runs, not after. Given as a string the
      # option means a path on the machine, which is the point of it (the private key stays out of /nix/store and
      # out of git); given as a store path it is already there and is filtered out here.
      initrdHostKeysOf =
        machineConfig:
        lib.optionals machineConfig.boot.initrd.network.ssh.enable (
          lib.filter (k: !lib.hasPrefix builtins.storeDir k) (
            map toString machineConfig.boot.initrd.network.ssh.hostKeys
          )
        );
      initrdHostKeys = lib.unique (initrdHostKeysOf cfg ++ initrdHostKeysOf cfgVMBoot);
      needsInitrdSecrets = cfg.boot.initrd.secrets != { } || cfgVMBoot.boot.initrd.secrets != { };
      provisionLuksKey = pkgs.writeShellApplication {
        name = "provision_luks_key";
        runtimeInputs = with pkgs; [
          coreutils
          util-linux
        ];
        text = builtins.readFile ./serverbase/scripts/provision-luks-key.sh;
      };
      nixos-system = lib.nixosSystem {
        modules = [
          (
            { config, ... }:
            {
              imports = [
                "${inputs.nixpkgs}/nixos/modules/installer/cd-dvd/iso-image.nix"
                "${inputs.nixpkgs}/nixos/modules/profiles/minimal.nix"
                "${inputs.nixpkgs}/nixos/modules/profiles/installation-device.nix"
              ];
              isoImage = {
                makeEfiBootable = true;
                makeUsbBootable = true;
                forceTextMode = true;
              };
              swapDevices = lib.mkImageMediaOverride [ ];
              fileSystems = lib.mkImageMediaOverride config.lib.isoFileSystems; # An installation media cannot tolerate a host config defined file system layout on a fresh machine, before it has been formatted.
              specialisation.serial.configuration = {
                isoImage.appendToMenuLabel = " Installer (serial)";
                boot.kernelParams = [
                  "console=ttyS0,115200n8" # this is for the serial console so connections with socat work
                ];
                environment.etc."serial_install".text = "true";
              };
              boot = {
                loader.grub.memtest86.enable = true; # Add Memtest86+ to the CD.
                postBootCommands = ''
                  for o in $(</proc/cmdline); do
                    case "$o" in
                      live.nixos.passwd=*)
                        set -- $(IFS==; echo $o)
                        echo "nixos:$2" | ${pkgs.shadow}/bin/chpasswd
                        ;;
                    esac
                  done
                '';
                loader.timeout = lib.mkForce 2;
                kernelParams = [
                  "console=ttyS0,115200n8" # this is for the serial console so connections with socat work
                  "console=tty0"
                ];
              };
              image.baseName = lib.mkForce cfg.setup.hostName;
              nixpkgs.pkgs = pkgs;
              fonts.fontconfig.enable = false; # Remove fonts to make ISO smaller
              networking.useDHCP = false;
              systemd.services.unattended-install = {
                description = "Unattended NixOS installation script";
                wantedBy = [ "multi-user.target" ];
                after = [ "getty.target" ]; # Prevent a login getty from starting so the script can output directly to the console
                conflicts = [
                  "getty@tty1.service"
                  "serial-getty@ttyS0.service"
                ];
                serviceConfig = {
                  Type = "oneshot";
                  StandardInput = "tty-force";
                };
                path = [

                  pkgs.nix
                  pkgs.nixos-install
                  pkgs.util-linux
                  pkgs.systemd
                  pkgs.kexec-tools
                  pkgs.openssh
                ];
                script =
                  let
                    kernelImage = "${cfg.boot.kernelPackages.kernel}/${cfg.system.boot.loader.kernelFile}";
                    initRamdisk = "${cfg.system.build.initialRamdisk}/${cfg.system.boot.loader.initrdFile}";
                    initScript = "${cfg.system.build.toplevel}/init";
                    kernelArgs = "init=${initScript} ${lib.concatStringsSep " " cfg.boot.kernelParams}";
                    vmBootKernelImage = "${cfgVMBoot.boot.kernelPackages.kernel}/${cfgVMBoot.system.boot.loader.kernelFile}";
                    vmBootInitRamdisk = "${cfgVMBoot.system.build.initialRamdisk}/${cfgVMBoot.system.boot.loader.initrdFile}";
                    vmBootInitScript = "${cfgVMBoot.system.build.toplevel}/init";
                    vmBootKernelArgs = "init=${vmBootInitScript} ${lib.concatStringsSep " " cfgVMBoot.boot.kernelParams}";
                  in
                  /* bash */ ''
                    ${lib.optionalString needsLuksKey ''
                      LUKS_KEY_FILE='${cfg.setup.luksKeyFile}' \
                      LUKS_KEY_HOSTNAME='${cfg.setup.hostName}' \
                      LUKS_KEY_ALLOW_WELLKNOWN='${if isDev then "1" else "0"}' \
                      LUKS_KEY_TARGET_DESCRIPTION='${cfg.setup.derivedHostName}' \
                        ${provisionLuksKey}/bin/provision_luks_key
                    ''}
                    echo ====== Partioning disk...
                    if systemd-detect-virt &>/dev/null; then
                      echo "====== In a VM"
                      ${cfgVMBoot.system.build.destroyFormatMount}/bin/disko-destroy-format-mount --yes-wipe-all-disks
                    else
                      ${cfg.system.build.destroyFormatMount}/bin/disko-destroy-format-mount --yes-wipe-all-disks
                    fi
                    ${lib.optionalString (initrdHostKeys != [ ]) ''
                      # A FRESH key per install, deliberately, and never one carried in on the media the way the age
                      # key and the root passphrase are. It is dedicated to the initrd, it lands unencrypted on an
                      # unencrypted boot partition either way, and a machine that has just been reinstalled is
                      # entitled to a new identity - the cost is one `known_hosts` entry on port 2222.
                      #
                      # Without it the install gets all the way through nixos-install and dies on the last step,
                      # `failed to create initrd secrets!`, which on a real machine is after the point of no return.
                      # The conversion runbook (PLAN_ENCRYPTION.md step 8a) creates it by hand for exactly this
                      # reason; an unattended install has nobody to do that.
                      for key in ${lib.escapeShellArgs initrdHostKeys}; do
                        target="/mnt$key"
                        if [ -f "$target" ]; then
                          echo "====== initrd ssh host key already at $target"
                          continue
                        fi
                        echo "====== Generating the initrd ssh host key at $target"
                        mkdir -p "$(dirname "$target")"
                        ssh-keygen -t ed25519 -N "" -C 'initrd@${cfg.setup.derivedHostName}' -f "$target"
                        # The same key at the INSTALLER's own path as well, because append-initrd-secrets reads
                        # its sources from wherever it is run, and it is run here rather than in the target. That
                        # is what lets the kexec below boot with the same initrd identity the disk will have.
                        mkdir -p "$(dirname "$key")"
                        cp "$target" "$key"
                      done
                    ''}
                    echo '====== Installing NixOS...'
                    if systemd-detect-virt &>/dev/null; then
                      nixos-install --system ${cfgVMBoot.system.build.toplevel} --no-root-passwd --substituters ""
                    else
                      nixos-install --system ${cfg.system.build.toplevel} --no-root-passwd --substituters ""
                    fi
                    echo '====== Installation complete, remember to eject the USB, CD, DVD or Blu-ray device!'
                    if systemd-detect-virt &>/dev/null; then
                      kernelArgs='${vmBootKernelArgs}'
                    else
                      kernelArgs='${kernelArgs}'
                    fi
                    if [ -f /etc/serial_install ]; then
                      kernelArgs+=' console=tty0 console=ttyS0,115200n8'
                    fi
                    if systemd-detect-virt &>/dev/null; then
                      initrdFile='${vmBootInitRamdisk}'
                      kernelImageFile='${vmBootKernelImage}'
                    else
                      initrdFile='${initRamdisk}'
                      kernelImageFile='${kernelImage}'
                    fi
                    ${lib.optionalString needsInitrdSecrets ''
                      # The store initrd has NO secrets in it. They are appended by the bootloader installer, to
                      # the copy it puts on the ESP - so every boot from disk has them and this one, which skips
                      # the bootloader entirely, would not. The symptom is a red `Failed to start Copy secrets
                      # into place` on the first boot of every install, and an initrd sshd that cannot start
                      # because its host key never arrived: the unit does `cd /.initrd-secrets`, the directory is
                      # not there, and `find` then walks / instead and copies nothing successfully.
                      #
                      # Doing it here makes the kexec boot a faithful preview of the disk boot rather than a
                      # special case to remember. Non-fatal on purpose: this is a convenience boot, and losing it
                      # is not worth failing an install that has already written the disk correctly.
                      echo '====== Appending the initrd secrets for the kexec boot...'
                      initrdWithSecrets=/tmp/initrd-with-secrets
                      cat "$initrdFile" > "$initrdWithSecrets"
                      if systemd-detect-virt &>/dev/null; then
                        appendSecrets=${cfgVMBoot.system.build.initialRamdiskSecretAppender}/bin/append-initrd-secrets
                      else
                        appendSecrets=${cfg.system.build.initialRamdiskSecretAppender}/bin/append-initrd-secrets
                      fi
                      if "$appendSecrets" "$initrdWithSecrets"; then
                        initrdFile=$initrdWithSecrets
                      else
                        echo '====== Could not append them; this one boot starts without its initrd secrets'
                      fi
                    ''}
                    echo "====== Kexec-ing new install (kexec -l --initrd=\"$initrdFile\" --command-line=\"$kernelArgs\" $kernelImageFile)..."
                    kexec -l --initrd="$initrdFile" --command-line="$kernelArgs" "$kernelImageFile"
                    kexec -e
                  '';
              };
              system.stateVersion = "26.05";
            }
          )
        ];
      };
      file = "${cfg.setup.hostName}${if isDev then "dev" else ""}${if isVM then "_vm" else ""}.iso";
    in
    pkgs.runCommand file { } ''
      mkdir -p "$out"
      ln -s ${nixos-system.config.system.build.isoImage}/iso/*.iso $out/${file}
    '';

  mkSdCardImage =
    {
      pkgs,
      nixos-system,
      isDev,
    }:
    let
      file = "${nixos-system.config.setup.hostName}${if isDev then "dev" else ""}.img.zst";
    in
    pkgs.runCommand file { } ''
      mkdir -p "$out"
      ln -s ${nixos-system.config.system.build.sdImage}/sd-image/*.img.zst $out/${file}
    '';

  mkVmImage =
    {
      pkgs,
      nixos-system,
      isDev,
    }:
    let
      file = "run-${nixos-system.config.setup.derivedHostName}-vm";
    in
    pkgs.runCommand file { } ''
      mkdir -p "$out"
      ln -s ${nixos-system.config.system.build.vm}/bin/${file} $out/${file}
    '';

  list_machines =
    { pkgs, machines, ... }:
    let
      machinesNames = map (m: m.name) machines;
      machinesNamesWithDev = machinesNames ++ (lib.map (m: "${m}dev") machinesNames);
      isoMachinesNames = map (m: m.name) (lib.filter (m: m.supportsIso) machines);
      isoMachinesNamesWithDev = isoMachinesNames ++ (lib.map (m: "${m}dev") isoMachinesNames);
      imgMachinesNames = map (m: m.name) (lib.filter (m: m.supportsImg) machines);
      # Machines whose card carries only the boot chain also get a boot-only image (see modules/setup-opi4pro-boot-image.nix).
      # Listed here so the Makefile's img rules cover `<name>boot.img.zst` like any other image.
      bootImgMachinesNames = map (m: "${m.name}boot") (
        lib.filter (m: m.supportsImg && (m.imgIsInstaller or false)) machines
      );
      imgMachinesNamesWithDev =
        imgMachinesNames
        ++ (lib.map (m: "${m}dev") imgMachinesNames)
        ++ bootImgMachinesNames
        ++ (lib.map (m: "${m.name}devboot") (
          lib.filter (m: m.supportsImg && (m.imgIsInstaller or false)) machines
        ));
    in
    pkgs.runCommand "list_machines" { } ''
      mkdir -p "$out/bin"
      echo -e '#!/usr/bin/env bash\n\necho -n "machines ${lib.strings.concatStringsSep " " machinesNamesWithDev}"' > "$out/bin/list_machines";
      echo 'echo -n "|isos ${lib.strings.concatStringsSep " " isoMachinesNamesWithDev}"' >> "$out/bin/list_machines";
      echo 'echo -n "|imgs ${lib.strings.concatStringsSep " " imgMachinesNamesWithDev}"' >> "$out/bin/list_machines";
      chmod +x "$out/bin/list_machines";
    '';

  machine_details =
    { pkgs, machines, ... }:
    let
      attrs = lib.lists.foldr (newConfig: configAccumulator: configAccumulator // newConfig) { } (
        (map (
          machine:
          (
            let
              command = pkgs.runCommand "machine_${machine.name}" { } ''
                mkdir -p "$out/bin"
                cat << EOF > "$out/bin/machine_${machine.name}"
                #!/usr/bin/env bash
                echo '${builtins.toJSON machine}'
                EOF
                chmod +x "$out/bin/machine_${machine.name}";
              '';
            in
            {
              "machine_${machine.name}" = command;
              "machine_${machine.name}dev" = command;
            }
          )
        ) machines)
      );
    in
    attrs;

  mkDevShells =
    {
      pkgs,
      system,
      extraModules ? [ ],
      # Appended to the shell hook, for a superproject with site-specific setup to do on entry - a directory of
      # scripts to put on PATH, a file of local addresses to source. Empty here, and it has to stay that way: this
      # repository must keep working standalone, and it has no site.
      extraShellHook ? "",
    }:
    let
      baseShell = {
        name = "Image build environment";
        buildInputs =
          with pkgs;
          [
            zstd
            util-linux
            sops
            iproute2
            attic-client
            markdownlint-cli2 # `make lint_md`
          ]
          ++ extraModules;
        shellHook = /* bash */ ''
          export VMS_DIR=$HOME/vms
          ${extraShellHook}
        '';
      };
      defaultShell = baseShell // {
        buildInputs =
          baseShell.buildInputs
          ++ (lib.optionals (system == "x86_64-linux") (
            with pkgs;
            [
              # these libs are used to build VMs, not necessary in the RPi or inside VMs
              zellij
              qemu
              # The software TPM the from-ISO VMs are launched with - see start-tpm.sh, which the Makefile copies
              # into each VM directory. gmktec1's root is sealed to a TPM, so a VM of it without one cannot
              # rehearse its own boot.
              swtpm
              tpm2-tools
              libguestfs-with-appliance
              guestfs-tools
              picocom # for serial communication
            ]
          ));
      };
    in
    {
      vm = pkgs.mkShell baseShell;
      default = pkgs.mkShell defaultShell;
    };
}
