{ lib, config, ... }:
with lib;
{
  options.setup = {
    virtualbox = mkEnableOption "Virtualbox enabled";
    username = mkOption {
      type = types.str;
      example = literalExpression "{ username = \"giggio\"; }";
    };
    servername = mkOption {
      type = types.str;
      example = literalExpression "{ servername = \"my_server\"; }";
    };
    configRepo = mkOption {
      type = types.str;
      default = "giggio/nixos_serverbase";
      description = "The repository to clone the configuration from";
    };
    nixosConfigDir = mkOption {
      type = types.str;
      default = "/home/${config.setup.username}/.config/nixos";
      description = "The directory to clone the configuration to";
    };
  };
}
