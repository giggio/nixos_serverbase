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
        type = types.int;
        default = 0;
        description = "Extra docker daemons to run.";
      };
    };
  };

  config =
    let
      cfg = config.virtualisation.docker;
      settingsFormat = pkgs.formats.json { };
      extraDaemons = lib.lists.range 2 (config.setup.docker.extra-daemons + 1);
    in
    {
      virtualisation.docker.enable = true;
      systemd.services = lib.foldr (a: b: a // b) { } (
        lib.map (
          i:
          let
            dockerService = "docker${toString i}";
            containerdService = "containerd${toString i}";
            containerdSocket = "${exec-root}/containerd/containerd.sock";
            data-root = "/var/lib/${dockerService}";
            exec-root = "/var/run/${dockerService}";
            daemonSettingsFile = settingsFormat.generate "daemon${toString i}.json" (
              cfg.daemon.settings
              // {
                # see: https://docs.docker.com/reference/cli/dockerd/#run-multiple-daemons
                inherit data-root exec-root;
                bridge = "container${toString i}";
                pidfile = "${exec-root}.pid";
                containerd = containerdSocket;
                iptables = false;
                ip6tables = false;
                ip-masq = false;
              }
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
                  "${cfg.package}/bin/dockerd --config-file=${daemonSettingsFile} ${cfg.extraOptions}"
                ];
                ExecReload = [ "${pkgs.procps}/bin/kill -s HUP $MAINPID" ];
              };
              environment = config.networking.proxy.envVars;
              path = [ pkgs.kmod ];
            };

            "${containerdService}" = {
              # this is an adaptation of the containerd service https://github.com/NixOS/nixpkgs/blob/1267bb4/nixos/modules/virtualisation/containerd.nix
              # The default docker daemon starts its own containerd, extra daemons need to create their own containerd service
              description = "containerd - container runtime (${toString i})";
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
        ) extraDaemons
      );

      systemd.sockets = lib.foldr (a: b: a // b) { } (
        lib.map (
          i:
          let
            dockerSocket = "docker${toString i}";
            containerdSocket = "containerd${toString i}";
            exec-root = "/var/run/${dockerSocket}";
          in
          {
            "${dockerSocket}" = {
              description = "Docker Socket for the API (${toString i})";
              wantedBy = [ "sockets.target" ];
              socketConfig = {
                ListenStream = [ "/run/${dockerSocket}.sock" ];
                SocketMode = "0660";
                SocketUser = "root";
                SocketGroup = "docker";
              };
            };
            "${containerdSocket}" = {
              description = "Containerd Socket for the Docker (${toString i})";
              wantedBy = [ "sockets.target" ];
              socketConfig = {
                ListenStream = [ "${exec-root}/containerd/containerd.sock" ];
                SocketMode = "0660";
                SocketUser = "root";
                SocketGroup = "root";
              };
            };
          }
        ) extraDaemons
      );

      # New interface and bridge are required, with NAT, so network works as expected
      systemd.network.networks = lib.foldr (a: b: a // b) { } (
        lib.map (i: {
          "40-container${toString i}" = {
            networkConfig.ConfigureWithoutCarrier = "yes";
            linkConfig.RequiredForOnline = "no";
          };
        }) extraDaemons
      );

      networking = {
        bridges = lib.foldr (a: b: a // b) { } (
          lib.map (i: {
            "container${toString i}" = {
              interfaces = [ ];
            };
          }) extraDaemons
        );
        interfaces = lib.foldr (a: b: a // b) { } (
          lib.map (i: {
            "container${toString i}" = {
              ipv4.addresses = [
                {
                  address = "172.${toString (37 + i)}.0.1";
                  prefixLength = 16;
                }
              ];
              useDHCP = false;
            };
          }) extraDaemons
        );
        nat = {
          enable = true;
          externalInterface = "eth0";
          internalInterfaces = lib.map (i: "container${toString i}") extraDaemons;
        };
      };
    };
}
