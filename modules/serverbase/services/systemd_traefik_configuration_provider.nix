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
    user = mkOption {
      type = types.str;
      description = ''
        The user the provider runs as. It owns the destination directory, which traefik's group can read.
      '';
      default = "traefik_provider";
    };
  };
  config =
    let
      cfg = config.services.systemd_traefik_configuration_provider;
    in
    lib.modules.mkIf (config.services.traefik.enable && cfg.enable) {
      users.users.${cfg.user} = {
        isSystemUser = true;
        group = "traefik";
      };
      # This module owns the directory when it is on. Owned by the provider and not by root, so the provider needs no
      # capability to write its files.
      systemd.tmpfiles.rules = [ "d ${cfg.destinationDirectory} 0750 ${cfg.user} traefik -" ];
      systemd.services.systemd_traefik_configuration_provider = {
        description = "Gathers info from systemd and publishes it as YAML configuration in the Traefik format";
        wantedBy = [ "multi-user.target" ];
        unitConfig = helpers.systemd.notifyUnitConfig;
        serviceConfig =
          (helpers.systemd.restartServiceConfig config)
          // helpers.systemd.hardened
          // {
            ExecStart = "${pkgs.systemd_traefik_configuration_provider}/bin/systemd_traefik_configuration_provider --log-hide-date";
            User = cfg.user;
            Group = "traefik";
            # It only reads unit metadata from the system bus (a filesystem socket, which a private network keeps) and
            # writes its yaml files. 0027 so traefik's group reads them.
            UMask = "0027";
            ReadWritePaths = [ cfg.destinationDirectory ];
            # The files an earlier, root-owned run left behind could not be rewritten by this user. Handing them over
            # keeps the routes in place while it starts, which deleting them would not. `+` runs only this line with
            # full privileges, and it is a no-op once everything is the provider's.
            ExecStartPre = "+${pkgs.findutils}/bin/find ${cfg.destinationDirectory} -maxdepth 1 -type f -name '*.service.yml' -user root -exec ${pkgs.coreutils}/bin/chown ${cfg.user}:traefik {} +";
            RestrictAddressFamilies = [ "AF_UNIX" ];
            PrivateNetwork = true;
          };
        environment = {
          TRAEFIK_OUT_DIR = cfg.destinationDirectory;
          RUST_LOG = "systemd_traefik_configuration_provider=info";
        };
      };
    };
}
