{ lib, ... }:
{
  systemd = {
    notifyUnitConfig = {
      OnFailure = "notify_telegram@%N.service";
    };
    restartServiceConfig = {
      Restart = lib.mkForce "always";
      RestartMaxDelaySec = lib.mkForce "10m";
      RestartSec = lib.mkForce 20;
      RestartSteps = lib.mkForce 3;
    };
    mkSystemdPackageForTraefik =
      {
        pkgs,
        host,
        port,
        serviceName,
      }:
      let
        traefikServiceRouterBase = "traefik.http.routers.${host}";
      in
      pkgs.runCommand "${host}_traefik_dropin" { } ''
        mkdir -p $out/lib/systemd/system/${serviceName}.service.d
        cat > $out/lib/systemd/system/${serviceName}.service.d/traefik_metadata.conf <<'EOF'
        [X-Traefik]
        Label=${traefikServiceRouterBase}.service=${host}
        Label=${traefikServiceRouterBase}.entrypoints=websecure
        Label=${traefikServiceRouterBase}.rule=Host(`${host}.giggio.dev`)
        Label=${traefikServiceRouterBase}.tls=true
        Label=${traefikServiceRouterBase}.tls.certresolver=le
        Label=${traefikServiceRouterBase}.tls.domains[0].main=*.giggio.dev
        Label=traefik.http.services.${host}.loadbalancer.servers[0].url=http://127.0.0.1:${toString port}
        EOF
      '';
  };
}
