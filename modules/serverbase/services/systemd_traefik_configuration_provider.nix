{
  lib,
  config,
  helpers,
  pkgs,
  ...
}:
{
  options.services.systemd_traefik_configuration_provider = with lib; {
    enable = mkEnableOption "systemd_traefik_configuration_provider enabled";
    destinationDirectory = mkOption {
      type = types.str;
      example = literalExpression "{ destinationDirectory = \"/etc/traefik/dynamic\"; }";
      default = "/etc/traefik/dynamic";
    };
  };
  config = {
    systemd.services.systemd_traefik_configuration_provider =
      lib.modules.mkIf
        (config.services.traefik.enable && config.services.systemd_traefik_configuration_provider.enable)
        {
          description = "Gathers info from systemd and publishes it as YAML configuration in the Traefik format";
          wantedBy = [ "multi-user.target" ];
          unitConfig = helpers.systemd.notifyUnitConfig;
          serviceConfig = helpers.systemd.restartServiceConfig // {
            ExecStart = "${pkgs.systemd_traefik_configuration_provider}/bin/systemd_traefik_configuration_provider --log-hide-date";
            Group = [ "traefik" ];
          };
          environment = {
            TRAEFIK_OUT_DIR = "${config.services.systemd_traefik_configuration_provider.destinationDirectory}";
            RUST_LOG = "systemd_traefik_configuration_provider=trace";
          };
        };
  };
}
