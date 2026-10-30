{ lib, utils, ... }:
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
      # Removes what the unit's User and Group own, not what the unit made, once the last unit running as either stops.
      # Switch it off on a unit whose User or Group is shared with processes that no unit runs as that User or Group.
      RemoveIPC = true;
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
    # A unit in a chroot of its own closure (nixpkgs' `confinement`), so a code execution in it sees the store paths its
    # `Exec*` lines need and the few files of /etc it is given, not the machine's whole store and /etc. Confinement also
    # turns on PrivateUsers, so the unit sees only its own user and root. What any networked program reads from /etc is
    # bound here: the resolver, the hosts file, the CA bundle, and an nsswitch.conf of its own, because the machine's
    # names `resolve` and `mymachines`, NSS modules the chroot does not have. And the time zone: without
    # /etc/localtime a program falls back to UTC, which moves its logs and its schedules. And passwd and group, which
    # every process on the machine can already read: without them looking up the unit's own uid fails, and .NET's
    # `Environment.UserName` throws, which took the servarr web interfaces down. The unit adds the rest:
    # - `BindReadOnlyPaths` for its configuration and secrets outside the store (a symlink's target is what is bound);
    # - `BindPaths` for what it writes outside StateDirectory and RuntimeDirectory, which systemd mounts in by itself
    #   (a `ReadWritePaths` names the host's path, which is not in the chroot);
    # - `packages` for what its scripts take from PATH, which confinement does not follow;
    # - its mount checks as `mountCheckDependencies`, not in a preStart.
    confined =
      {
        pkgs,
        packages ? [ ],
      }:
      {
        confinement = {
          enable = true;
          inherit packages;
        };
        serviceConfig.BindReadOnlyPaths = [
          "-/etc/resolv.conf"
          "-/etc/hosts"
          "-/etc/localtime"
          "-/etc/passwd"
          "-/etc/group"
          "/etc/ssl/certs/ca-certificates.crt"
          "${pkgs.writeText "confined-nsswitch.conf" ''
            passwd: files
            group: files
            hosts: files dns
          ''}:/etc/nsswitch.conf"
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
    # `checkMountScript` for a `confined` unit: it requires the `mount-check@` instance of each path, which runs the
    # check outside the chroot. Inside, every bound path is a mount point whether or not the filesystem behind it is
    # mounted, and even a `+` command runs in the chroot, where /proc is not mounted. The instance does not remain
    # active, so it runs again at every start of the unit, as a preStart would.
    mountCheckDependencies =
      mounts:
      let
        units = map (mount: "mount-check@${utils.escapeSystemdPath mount}.service") mounts;
      in
      {
        requires = units;
        after = units;
      };
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
