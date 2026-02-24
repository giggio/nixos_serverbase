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
    vm = {
      enable = mkEnableOption "VM enabled";
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
      useEFIBoot = mkEnableOption "EFI boot enabled";
    };
  };
  config.setup = {
    isDev = (config.setup.environment == "dev") || (config.setup.environment == "test");
    isProd = config.setup.environment == "prod";
    isTest = config.setup.environment == "test";
    derivedHostName = "${config.setup.hostName}${if config.setup.isDev then "dev" else ""}";
  };
}
