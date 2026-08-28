{ lib, config, ... }:
with lib;
{
  options.setup = {
    environment = mkOption {
      type = types.enum [
        "dev"
        "prod"
        "test"
      ];
      default = "prod";
      example = literalExpression "{ environment = \"dev\"; }";
    };
    isDev = mkOption {
      type = types.bool;
      readOnly = true;
      description = "Computed from setup.environment.";
    };
    isProd = mkOption {
      type = types.bool;
      readOnly = true;
      description = "Computed from setup.environment.";
    };
    isTest = mkOption {
      type = types.bool;
      readOnly = true;
      description = "Computed from setup.environment.";
    };
    isVM = mkOption {
      type = types.bool;
      readOnly = true;
      description = "Computed from setup.vm.enable";
    };
    isVMBoot = mkOption {
      type = types.bool;
      readOnly = true;
      description = "Computed from setup.vm.boot.enable";
    };
    username = mkOption {
      type = types.str;
      example = literalExpression "{ username = \"giggio\"; }";
    };
    hostName = mkOption {
      type = types.str;
      example = literalExpression "{ hostName = \"my_server\"; }";
    };
    derivedHostName = mkOption {
      type = types.str;
      readOnly = true;
    };

    # WHERE THE INSTALLER LEAVES THE ROOT PASSPHRASE, and where disko's format step goes looking for it.
    #
    # An option rather than the same string written twice, because the two ends are in modules that cannot see
    # each other: a machine's `disko.devices...content.passwordFile` (config-physical-gmktec.nix) and the ISO's
    # unattended-install service (lib.nix). Written as literals they agree by coincidence, and when they stop
    # agreeing the symptom is `cryptsetup luksFormat` sitting at a passphrase prompt on a machine with no
    # keyboard attached and no getty running - which is exactly how this option came to exist.
    #
    # /tmp because it must NOT survive the install: it lives in the installer's tmpfs, is read once by
    # luksFormat, and is gone when the machine reboots into the system it just installed. Nothing copies it to
    # the target root, and nothing should.
    luksKeyFile = mkOption {
      type = types.str;
      default = "/tmp/luks_key";
      description = ''
        Path, inside the installer, of the file holding the root LUKS passphrase. Only ever read when disko
        formats - so it matters for a machine installed from the ISO, and not at all for one converted in place.
      '';
    };
    vm = {
      enable = mkEnableOption "VM enabled";
      boot.enable = mkEnableOption "VM boot enabled";
      memorySize = mkOption {
        type = types.int;
        default = 4;
        description = "Virtual machine memory size in GB";
      };
      diskSize = mkOption {
        type = types.int;
        default = 48;
        description = "Virtual machine disk size in GB";
      };
      extraDisks = mkOption {
        type = types.listOf types.int;
        default = [ ];
        description = "Number of extra disks to add";
      };
      extraStartCommands = mkOption {
        type = types.lines;
        default = "";
        description = "Extra commands to be ran when creating the vm";
      };
      extraCreateCommands = mkOption {
        type = types.lines;
        default = "";
        description = "Extra commands to be added to the run-vm file";
      };
      useEFIBoot = mkEnableOption "EFI boot enabled";
    };
  };
  config.setup = {
    isDev = (config.setup.environment == "dev") || (config.setup.environment == "test");
    isProd = config.setup.environment == "prod";
    isTest = config.setup.environment == "test";
    isVM = config.setup.vm.enable;
    isVMBoot = config.setup.vm.boot.enable;
    derivedHostName = "${config.setup.hostName}${if config.setup.isDev then "dev" else ""}${
      if config.setup.isVM then "vm${if config.setup.isVMBoot then "boot" else ""}" else ""
    }";

  };
}
