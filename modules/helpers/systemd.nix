{ lib, ... }:
{
  systemd = rec {
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
    # The least-privilege baseline for a unit this configuration provides. A unit merges it (`// hardened`) and adds
    # only its exceptions: a path to write in `ReadWritePaths`, the address families it talks over, a capability it
    # cannot do without, `MemoryDenyWriteExecute = false` for a JIT. A property is switched off by naming it again,
    # never by leaving the baseline out. Tested per unit with `systemd-analyze security --threshold`.
    hardened = {
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectClock = true;
      ProtectHostname = true;
      ProtectProc = "invisible";
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      SystemCallArchitectures = "native";
      SystemCallFilter = [
        "@system-service"
        "~@privileged"
      ];
      CapabilityBoundingSet = [ "" ];
      UMask = "0077";
    };
    # `hardened` for a job that reads backups from the shares and uploads them: no account of its own to keep (the
    # shares are mounted with a forced owner, so the groups are what grant access), the network for tang and the
    # bucket, and nothing it writes outlives the run. The unit has to set `RuntimeDirectory = "%N"`: rclone wants a home
    # and a cache directory and gets that one.
    hardenedUpload =
      groups:
      hardened
      // {
        DynamicUser = true;
        SupplementaryGroups = groups;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        Environment = [
          "HOME=%t/%N"
          "XDG_CACHE_HOME=%t/%N"
        ];
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
        # The certificate resolver the router names, or null on a machine that has none. Traefik does not stop on a
        # router naming a resolver it does not have: it logs `Router uses a nonexistent certificate resolver` as an
        # error for that router on every configuration reload, and serves it with the default certificate anyway. So a
        # machine that receives its certificate as a file (see `setup.traefik.issuesCertificates` in the sibling
        # repository) should pass null, which keeps that error out of its log: the router then carries only `tls=true`.
        # Null also leaves out the wildcard domain, which is only ever a request to the resolver.
        certResolver ? "le",
      }:
      let
        traefikServiceRouterBase = "traefik.http.routers.${host}";
        labels = [
          "Label=${traefikServiceRouterBase}.service=${host}"
          "Label=${traefikServiceRouterBase}.entrypoints=websecure"
          "Label=${traefikServiceRouterBase}.rule=Host(`${host}.${domain}`)"
          "Label=${traefikServiceRouterBase}.tls=true"
        ]
        ++ lib.optionals (certResolver != null) [
          "Label=${traefikServiceRouterBase}.tls.certresolver=${certResolver}"
          "Label=${traefikServiceRouterBase}.tls.domains[0].main=*.${domain}"
        ]
        ++ [
          "Label=traefik.http.services.${host}.loadbalancer.servers[0].url=http://127.0.0.1:${toString port}"
        ];
      in
      pkgs.runCommand "${host}_traefik_dropin" { } (
        (/* bash */ ''
          mkdir -p $out/lib/systemd/system/${serviceName}.service.d
          cat > $out/lib/systemd/system/${serviceName}.service.d/traefik_metadata.conf <<'EOF'
          [X-Traefik]
          ${lib.concatStringsSep "\n" labels}
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
