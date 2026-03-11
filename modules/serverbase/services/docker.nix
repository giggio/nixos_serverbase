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
        type = types.attrsOf (
          types.submodule (
            { name, ... }:
            {
              options = {
                kata-runtime.enable = mkEnableOption "Use kata runtime in this daemon";
                name = mkOption {
                  type = types.str;
                  readOnly = true;
                };
                socket = {
                  user = mkOption {
                    type = types.str;
                    default = "root";
                  };
                  group = mkOption {
                    type = types.str;
                    default = "docker";
                  };
                };
                network = {
                  disableICC = mkEnableOption "Disable inter container communication in this daemon";
                  interfaceName = mkOption {
                    type = types.str;
                    readOnly = true;
                  };
                };
                configuration = mkOption {
                  type = types.attrs;
                  default = { };
                  example = literalExpression "{ tls = true; }";
                  description = "Extra configuration for the daemon. See the dockerd documentation at https://docs.docker.com/reference/cli/dockerd/.";
                };
              };
              config = {
                inherit name;
                network.interfaceName =
                  let
                    largerName = "container-${name}";
                    smallerName = builtins.substring 0 15 "ctn-${name}";
                  in
                  if (builtins.stringLength largerName) < 16 then largerName else smallerName;
              };
            }
          )
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
      daemonsWithIndex =
        lib.attrsets.attrValues
          (lib.foldlAttrs
            (acc: name: value: {
              counter = acc.counter + 1;
              result = acc.result // {
                ${name} = value // {
                  index = acc.counter;
                };
              };
            })
            {
              counter = 0;
              result = { };
            }
            config.setup.docker.extra-daemons
          ).result;
    in
    {
      virtualisation.docker.enable = true;
      systemd.services = lib.foldr (a: b: a // b) { } (
        builtins.map (
          daemon:
          let
            suffix = "-${daemon.name}";
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
                bridge = daemon.network.interfaceName;
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
              description = "containerd - container runtime (${daemon.name})";
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
        ) daemonsWithIndex
      );

      systemd.sockets = lib.foldr (a: b: a // b) { } (
        builtins.map (
          daemon:
          let
            suffix = "-${daemon.name}";
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
                SocketUser = daemon.socket.user;
                SocketGroup = daemon.socket.group;
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
        ) daemonsWithIndex
      );

      # New interface and bridge are required, with NAT, so network works as expected
      systemd.network.networks = lib.foldr (a: b: a // b) { } (
        builtins.map (daemon: {
          "40-${daemon.network.interfaceName}" = {
            networkConfig.ConfigureWithoutCarrier = "yes";
            linkConfig.RequiredForOnline = "no";
          };
        }) daemonsWithIndex
      );

      networking = {
        bridges = lib.foldr (a: b: a // b) { } (
          builtins.map (daemon: {
            "${daemon.network.interfaceName}" = {
              interfaces = [ ];
            };
          }) daemonsWithIndex
        );
        interfaces = lib.foldr (a: b: a // b) { } (
          builtins.map (daemon: {
            "${daemon.network.interfaceName}" = {
              ipv4.addresses = [
                {
                  address = "172.${toString (39 + daemon.index)}.0.1";
                  prefixLength = 16;
                }
              ];
              useDHCP = false;
            };
          }) daemonsWithIndex
        );
        nat = {
          enable = true;
          externalInterface = "eth0";
          internalInterfaces = builtins.map (daemon: daemon.network.interfaceName) daemonsWithIndex;
        };
        firewall =
          let
            extraCommands = builtins.concatStringsSep "\n" (
              builtins.map (
                daemon:
                let
                  dockerHostNetInterfaceName = daemon.network.interfaceName;
                in
                ''
                  # Disabling ICC (inter container communication) for docker daemon ${daemon.name} containers
                  iptables -A FORWARD -i ${dockerHostNetInterfaceName} -o ${dockerHostNetInterfaceName} -j DROP
                ''
              ) (builtins.filter (daemon: daemon.network.disableICC) daemonsWithIndex)
            );
          in
          {
            inherit extraCommands;
            extraStopCommands = builtins.replaceStrings [ " -I " " -A " ] [ " -D " " -D " ] extraCommands;
          };
      };
    };
}
