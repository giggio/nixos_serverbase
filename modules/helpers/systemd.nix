{ lib, ... }:
{
  systemd = {
    notifyUnitConfig = {
      OnFailure = "notify_telegram@%N.service";
    };
    infiniteRetriesUnitConfig = {
      StartLimitIntervalSec = "0"; # Allow infinite retries
    };
    # Takes the machine's `config` because the policy depends on the environment: restarting forever is what keeps a
    # service alive on a real server, but in a test it only keeps a genuine failure out of `systemctl --failed` for as
    # long as the test runs, so a test build fails fast and visibly instead.
    restartServiceConfig =
      config:
      if config.setup.isTest then
        { Restart = lib.mkForce "no"; }
      else
        {
          Restart = lib.mkForce "always";
          RestartMaxDelaySec = lib.mkForce "10m";
          RestartSec = lib.mkForce 20;
          RestartSteps = lib.mkForce 3;
        };
    checkMountScript =
      mounts:
      lib.strings.concatStrings (
        lib.map (mount: ''
          if ! grep -q ${mount} /proc/self/mounts; then
            echo "The mount at ${mount} is not mounted."
            exit 1
          fi
          if ! timeout 3 stat ${mount} >/dev/null; then
            echo "The mount at ${mount} is hanged."
            exit 1
          fi
        '') mounts
      );
    mkSystemdPackageForTraefik =
      {
        pkgs,
        host,
        port,
        serviceName,
        domain,
        isDev ? false,
      }:
      let
        traefikServiceRouterBase = "traefik.http.routers.${host}";
      in
      pkgs.runCommand "${host}_traefik_dropin" { } (
        (/* bash */ ''
          mkdir -p $out/lib/systemd/system/${serviceName}.service.d
          cat > $out/lib/systemd/system/${serviceName}.service.d/traefik_metadata.conf <<'EOF'
          [X-Traefik]
          Label=${traefikServiceRouterBase}.service=${host}
          Label=${traefikServiceRouterBase}.entrypoints=websecure
          Label=${traefikServiceRouterBase}.rule=Host(`${host}.${domain}`)
          Label=${traefikServiceRouterBase}.tls=true
          Label=${traefikServiceRouterBase}.tls.certresolver=le
          Label=${traefikServiceRouterBase}.tls.domains[0].main=*.${domain}
          Label=traefik.http.services.${host}.loadbalancer.servers[0].url=http://127.0.0.1:${toString port}
          EOF
        '')
        + (lib.strings.optionalString isDev /* bash */ ''
          cat > $out/lib/systemd/system/${serviceName}.service.d/traefik_metadata_insecure.conf <<'EOF'
          [X-Traefik]
          Label=${traefikServiceRouterBase}_insecure.service=${host}
          Label=${traefikServiceRouterBase}_insecure.entrypoints=web
          Label=${traefikServiceRouterBase}_insecure.rule=Host(`${host}.${domain}`)
          EOF
        '')
      );
  };
}
