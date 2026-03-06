{
  pkgs,
  lib,
  config,
  ...
}:

{
  options = {
    setup.docker = with lib; {
      extra-daemons = mkOption {
        type = types.listOf (
          types.submodule {
            options = {
              kata-runtime.enable = mkEnableOption "Use kata runtime in this daemon";
              name = mkOption {
                type = types.nullOr types.str;
                default = null;
                example = literalExpression "{ name = \"kata\"; }";
              };
              network.disableICC = mkEnableOption "Disable inter container communication in this daemon";
              configuration = mkOption {
                type = types.attrs;
                default = { };
                example = literalExpression "{ tls = true; }";
                description = "Extra configuration for the daemon. See the dockerd documentation at https://docs.docker.com/reference/cli/dockerd/.";
              };
            };
          }
        );
        default = [ ];
        description = "Extra docker daemons to run.";
      };
    };
  };

  config =
    let
      cfg = config.virtualisation.docker;
      settingsFormat = pkgs.formats.json { };
      mkSuffix =
        n: daemon:
        if ((daemon ? name) && !builtins.isNull (daemon.name)) then
          "${daemon.name}"
        else
          (toString (n + 2));
      mkInterfaceName =
        n: daemon:
        let
          name = "container-${mkSuffix n daemon}";
          smallerName = "ctn-${mkSuffix n daemon}";
          smallestName = "container-${toString (n + 2)}";
        in
        if (builtins.stringLength name) < 16 then
          name
        else if (builtins.stringLength smallerName) < 16 then
          smallerName
        else
          smallestName;
    in
    {
      virtualisation.docker.enable = true;
      systemd.services = lib.foldr (a: b: a // b) { } (
        lib.lists.imap0 (
          n: daemon:
          let
            suffix = "-${mkSuffix n daemon}";
            dockerService = "docker${suffix}";
            containerdService = "containerd${suffix}";
            containerdSocket = "${exec-root}/containerd/containerd.sock";
            data-root = "/var/lib/${dockerService}";
            exec-root = "/var/run/${dockerService}";
            daemonSettingsFile = settingsFormat.generate "daemon${suffix}.json" (
              cfg.daemon.settings
              // {
                # see: https://docs.docker.com/reference/cli/dockerd/#run-multiple-daemons
                inherit data-root exec-root;
                bridge = mkInterfaceName n daemon;
                pidfile = "${exec-root}.pid";
                containerd = containerdSocket;
                iptables = false;
                ip6tables = false;
                ip-masq = false;
                default-runtime = if daemon.kata-runtime.enable then "kata" else "runc";
                runtimes = lib.attrsets.optionalAttrs daemon.kata-runtime.enable {
                  kata = {
                    runtimeType = "${pkgs.kata-runtime}/bin/containerd-shim-kata-v2";
                  };
                };
              }
              // daemon.configuration
            );
          in
          {
            "${dockerService}" = {
              # this is an adaptation of the original docker servide at https://github.com/NixOS/nixpkgs/blob/1267bb4/nixos/modules/virtualisation/docker.nix#L265
              wantedBy = [ "multi-user.target" ];
              after = [
                "network.target"
                "${dockerService}.socket"
                "${containerdService}.service"
              ];
              requires = [
                "${dockerService}.socket"
                "${containerdService}.service"
              ];
              serviceConfig = {
                Type = "notify";
                ExecStart = [
                  # todo: kata-runtime network is broken with docker 28+: https://github.com/kata-containers/kata-containers/issues/9340
                  # PR: https://github.com/kata-containers/kata-containers/pull/11749
                  "${
                    if daemon.kata-runtime.enable then pkgs.docker_25 else cfg.package
                  }/bin/dockerd --config-file=${daemonSettingsFile} ${cfg.extraOptions}"
                ];
                ExecReload = [ "${pkgs.procps}/bin/kill -s HUP $MAINPID" ];
              };
              environment = config.networking.proxy.envVars;
              path = [ pkgs.kmod ];
            };

            "${containerdService}" = {
              # this is an adaptation of the containerd service https://github.com/NixOS/nixpkgs/blob/1267bb4/nixos/modules/virtualisation/containerd.nix
              # The default docker daemon starts its own containerd, extra daemons need to create their own containerd service
              description = "containerd - container runtime (${mkSuffix n daemon})";
              wantedBy = [ "multi-user.target" ];
              after = [
                "network.target"
                "local-fs.target"
                "dbus.service"
              ];
              path = with pkgs; [
                containerd
                runc
                iptables
              ];
              unitConfig = {
                StartLimitBurst = "16";
                StartLimitIntervalSec = "120s";
              };
              serviceConfig =
                let
                  settingsFormat = pkgs.formats.toml { };
                  configFile = settingsFormat.generate "containerd.toml" {
                    disabled_plugins = [ "io.containerd.grpc.v1.cri" ];
                    imports = [ ];
                    oom_score = 0;
                    required_plugins = [ ];
                    root = "${data-root}/containerd/daemon";
                    state = "${exec-root}/containerd/daemon";
                    temp = "";
                    version = 2;
                    cgroup = {
                      path = "";
                    };
                    debug = {
                      address = "${exec-root}/containerd/containerd-debug.sock";
                      format = "text";
                      gid = 0;
                      level = "";
                      uid = 0;
                    };
                    grpc = {
                      address = containerdSocket;
                      gid = 0;
                      max_recv_message_size = 16777216;
                      max_send_message_size = 16777216;
                    };
                  };
                in
                {
                  ExecStart = "${pkgs.containerd}/bin/containerd --config ${configFile}";
                  Delegate = "yes";
                  KillMode = "process";
                  Type = "notify";
                  Restart = "always";
                  RestartSec = "10";
                  LimitNPROC = "infinity";
                  LimitCORE = "infinity";
                  TasksMax = "infinity";
                  OOMScoreAdjust = "-999";
                  StateDirectory = "containerd";
                  RuntimeDirectory = "containerd";
                  RuntimeDirectoryPreserve = "yes";
                };
            };

          }
        ) config.setup.docker.extra-daemons
      );

      systemd.sockets = lib.foldr (a: b: a // b) { } (
        lib.lists.imap0 (
          n: daemon:
          let
            suffix = "-${mkSuffix n daemon}";
            dockerSocket = "docker${suffix}";
            containerdSocket = "containerd${suffix}";
            exec-root = "/var/run/${dockerSocket}";
          in
          {
            "${dockerSocket}" = {
              description = "Docker Socket for the API (${suffix})";
              wantedBy = [ "sockets.target" ];
              socketConfig = {
                ListenStream = [ "/run/${dockerSocket}.sock" ];
                SocketMode = "0660";
                SocketUser = "root";
                SocketGroup = "docker";
              };
            };
            "${containerdSocket}" = {
              description = "Containerd Socket for the Docker (${suffix})";
              wantedBy = [ "sockets.target" ];
              socketConfig = {
                ListenStream = [ "${exec-root}/containerd/containerd.sock" ];
                SocketMode = "0660";
                SocketUser = "root";
                SocketGroup = "root";
              };
            };
          }
        ) config.setup.docker.extra-daemons
      );

      # New interface and bridge are required, with NAT, so network works as expected
      systemd.network.networks = lib.foldr (a: b: a // b) { } (
        lib.lists.imap0 (n: daemon: {
          "40-${mkInterfaceName n daemon}" = {
            networkConfig.ConfigureWithoutCarrier = "yes";
            linkConfig.RequiredForOnline = "no";
          };
        }) config.setup.docker.extra-daemons
      );

      networking = {
        bridges = lib.foldr (a: b: a // b) { } (
          lib.lists.imap0 (n: daemon: {
            "${mkInterfaceName n daemon}" = {
              interfaces = [ ];
            };
          }) config.setup.docker.extra-daemons
        );
        interfaces = lib.foldr (a: b: a // b) { } (
          lib.lists.imap0 (n: daemon: {
            "${mkInterfaceName n daemon}" = {
              ipv4.addresses = [
                {
                  address = "172.${toString (39 + n)}.0.1";
                  prefixLength = 16;
                }
              ];
              useDHCP = false;
            };
          }) config.setup.docker.extra-daemons
        );
        nat = {
          enable = true;
          externalInterface = "eth0";
          internalInterfaces = lib.lists.imap0 (
            n: daemon: mkInterfaceName n daemon
          ) config.setup.docker.extra-daemons;
        };
        firewall.extraCommands = builtins.concatStringsSep "\n" (
          lib.lists.imap0 (
            n: daemon:
            let
              dockerHostNetInterfaceName = mkInterfaceName n daemon;
            in
            ''
              iptables -A FORWARD -i ${dockerHostNetInterfaceName} -o ${dockerHostNetInterfaceName} -j DROP
            ''
          ) (builtins.filter (daemon: daemon.network.disableICC) config.setup.docker.extra-daemons)
        );
      };
    };
}
