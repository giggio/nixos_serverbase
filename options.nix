{ lib, ... }:
with lib;
{
  options.setup = {
    virtualbox = mkEnableOption "Virtualbox enabled";
    username = mkOption {
      type = types.str;
      example = literalExpression "{ username = \"giggio\"; }";
    };
  };
}
