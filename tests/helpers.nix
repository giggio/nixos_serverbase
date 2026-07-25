{ pkgs, lib, ... }:

# Covers modules/helpers. These are pure functions and small generators, so this check is a plain derivation rather than
# a nixosTest: there is nothing to boot, and it finishes in seconds. The values it asserts are the ones every service in
# both repositories is wired with, so a change here that looks harmless is caught before it reaches a machine.
let
  helpers = import ../modules/helpers { inherit lib; };

  unitTests = lib.runTests {
    testProxyNetworkNamesAreDerivedFromTheNetworkName = {
      expr = helpers.network.proxyNetwork;
      expected = {
        name = "proxy";
        serviceName = "docker-network-proxy";
        service = "docker-network-proxy.service";
        targetName = "docker-network-proxy-root";
        target = "docker-network-proxy-root.target";
      };
    };

    testAFailedUnitNotifiesTelegramAboutItself = {
      expr = helpers.systemd.notifyUnitConfig;
      expected.OnFailure = "notify_telegram@%N.service";
    };

    testInfiniteRetriesRemovesTheStartLimit = {
      expr = helpers.systemd.infiniteRetriesUnitConfig;
      expected.StartLimitIntervalSec = "0";
    };

    testAServiceRestartsForeverOutsideOfTests = {
      expr = lib.mapAttrs (_: value: value.content) (
        helpers.systemd.restartServiceConfig { setup.isTest = false; }
      );
      expected = {
        Restart = "always";
        RestartMaxDelaySec = "10m";
        RestartSec = 20;
        RestartSteps = 3;
      };
    };

    testAServiceFailsFastInATest = {
      expr = lib.mapAttrs (_: value: value.content) (
        helpers.systemd.restartServiceConfig { setup.isTest = true; }
      );
      expected.Restart = "no";
    };

    # the whole point of the helper is to win over whatever restart policy a service's own module already set
    testTheRestartPolicyOverridesTheModulesOwn = {
      expr = (helpers.systemd.restartServiceConfig { setup.isTest = false; }).Restart.priority;
      expected = (lib.mkForce null).priority;
    };
  };

  mkMountCheck = name: mounts: pkgs.writeShellScript name (helpers.systemd.checkMountScript mounts);
  # /proc is always in /proc/self/mounts, including inside the build sandbox
  mountedCheck = mkMountCheck "mounted-check" [ "/proc" ];
  unmountedCheck = mkMountCheck "unmounted-check" [ "/definitely-not-a-mount" ];

  traefikDropin =
    isDev:
    helpers.systemd.mkSystemdPackageForTraefik {
      inherit pkgs isDev;
      host = "myapp";
      port = 8080;
      serviceName = "myapp-server";
      domain = "example.test";
    };
  traefikProd = traefikDropin false;
  traefikDev = traefikDropin true;
  dropinDir = "lib/systemd/system/myapp-server.service.d";
in
pkgs.runCommand "helpers"
  {
    failures = builtins.toJSON unitTests;
  }
  ''
    if [ "$failures" != "[]" ]; then
      echo "helpers unit tests failed:" >&2
      echo "$failures" >&2
      exit 1
    fi

    echo "checkMountScript passes for a directory that is mounted"
    ${mountedCheck}

    echo "checkMountScript fails for a directory that is not mounted"
    if ${unmountedCheck}; then
      echo "the mount check passed for a path that is not mounted" >&2
      exit 1
    fi

    echo "the traefik drop-in routes the host over TLS to its local port"
    metadata="${traefikProd}/${dropinDir}/traefik_metadata.conf"
    grep -qF 'Label=traefik.http.routers.myapp.rule=Host(`myapp.example.test`)' "$metadata"
    grep -qF 'Label=traefik.http.routers.myapp.entrypoints=websecure' "$metadata"
    grep -qF 'Label=traefik.http.routers.myapp.tls.certresolver=le' "$metadata"
    grep -qF 'Label=traefik.http.routers.myapp.tls.domains[0].main=*.example.test' "$metadata"
    grep -qF 'Label=traefik.http.services.myapp.loadbalancer.servers[0].url=http://127.0.0.1:8080' "$metadata"

    echo "only a dev drop-in also serves the host over plain http"
    test ! -e "${traefikProd}/${dropinDir}/traefik_metadata_insecure.conf"
    insecure="${traefikDev}/${dropinDir}/traefik_metadata_insecure.conf"
    grep -qF 'Label=traefik.http.routers.myapp_insecure.entrypoints=web' "$insecure"
    grep -qF 'Label=traefik.http.routers.myapp_insecure.rule=Host(`myapp.example.test`)' "$insecure"
    test -e "${traefikDev}/${dropinDir}/traefik_metadata.conf"

    touch $out
  ''
