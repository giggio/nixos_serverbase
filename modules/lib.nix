{
  serverbaseModules,
  lib,
  inputs,
}:
{
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
                {
                  "${machine.name}" = nixosConfigurations."${machine.name}${arch}";
                  "${machine.name}vmboot" = nixosConfigurations."${machine.name}${arch}vmboot";
                  "${machine.name}dev" = nixosConfigurations."${machine.name}dev${arch}";
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

  mkNixosMachineCombinations =
    machines:
    let
      combinations =
        builtins.filter
          # only build if architecture matches or it is a vm
          (combination: (combination.isVM || combination.machine.defaultArch == combination.system))
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
      pi4Machines = builtins.filter (
        machine: machine.hardwareModule == serverbaseModules.hardware.pi4
      ) machines;
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
          map (machine: {
            "${machine.name}_img" = serverbaseModules.lib.mkPi4Image {
              pkgs = import inputs.nixpkgs { system = "${machine.defaultArch}-linux"; };
              nixos-system = nixosConfigurations."${machine.name}";
              isDev = false;
            };
            "${machine.name}dev_img" = serverbaseModules.lib.mkPi4Image {
              pkgs = import inputs.nixpkgs { system = "${machine.defaultArch}-linux"; };
              nixos-system = nixosConfigurations."${machine.name}dev";
              isDev = true;
            };
          }) pi4Machines
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
                    echo ====== Partioning disk...
                    if systemd-detect-virt &>/dev/null; then
                      echo "====== In a VM"
                      ${cfgVMBoot.system.build.destroyFormatMount}/bin/disko-destroy-format-mount --yes-wipe-all-disks
                    else
                      ${cfg.system.build.destroyFormatMount}/bin/disko-destroy-format-mount --yes-wipe-all-disks
                    fi
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
                      echo "====== Kexec-ing new install (kexec -l --initrd='${vmBootInitRamdisk}' --command-line=\"$kernelArgs\" ${vmBootKernelImage})..."
                      kexec -l --initrd='${vmBootInitRamdisk}' --command-line="$kernelArgs" ${vmBootKernelImage}
                    else
                      echo "====== Kexec-ing new install (kexec -l --initrd='${initRamdisk}' --command-line=\"$kernelArgs\" ${kernelImage})..."
                      kexec -l --initrd='${initRamdisk}' --command-line="$kernelArgs" ${kernelImage}
                    fi
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

  mkPi4Image =
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
      imgMachinesNamesWithDev = imgMachinesNames ++ (lib.map (m: "${m}dev") imgMachinesNames);
    in
    pkgs.runCommand "list_machines" { } ''
      mkdir -p "$out/bin"
      echo -e '#!/usr/bin/env bash\n\necho -n "machines ${lib.strings.concatStringsSep " " machinesNamesWithDev}"' > "$out/bin/list_machines";
      echo 'echo -n "|isos ${lib.strings.concatStringsSep " " isoMachinesNamesWithDev}"' >> "$out/bin/list_machines";
      echo 'echo -n "|imgs ${lib.strings.concatStringsSep " " imgMachinesNamesWithDev}"' >> "$out/bin/list_machines";
      chmod +x "$out/bin/list_machines";
    '';

  mkDevShells =
    {
      pkgs,
      system,
      extraModules ? [ ],
    }:
    let
      baseShell = {
        name = "Image build environment";
        buildInputs =
          with pkgs;
          [
            util-linux
            sops
          ]
          ++ extraModules;
        shellHook = /* bash */ ''
          export VMS_DIR=$HOME/vms
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
              libguestfs-with-appliance
              guestfs-tools
            ]
          ));
      };
    in
    {
      vm = pkgs.mkShell baseShell;
      default = pkgs.mkShell defaultShell;
    };
}
