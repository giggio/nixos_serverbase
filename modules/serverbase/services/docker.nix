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
                kata-runtime = {
                  enable = mkEnableOption "Use kata runtime in this daemon";
                  memory = mkOption {
                    type = types.int;
                    default = 4096;
                    description = "Memory available to the VM in MiB";
                  };
                  cpus = mkOption {
                    type = types.int;
                    default = -1;
                    description = "Number of cpus available to the VM (<0 == number of hosts CPU)";
                  };
                };
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
                  disableICC = {
                    enable = mkEnableOption "Disable inter container communication in this daemon";
                    portExceptions = mkOption {
                      type = types.listOf types.int;
                      description = "Ports to allow";
                      default = [ ];
                      example = literalExpression "[ 1234 5678 ]";
                    };
                  };
                  subnetOctet = mkOption {
                    type = types.ints.between 32 254;
                    example = 41;
                    description = ''
                      Second octet N of this daemon's bridge network 172.N.0.0/16; the
                      bridge gets 172.N.0.1 as its gateway. Must be unique across all
                      daemons (enforced by assertion) and must stay stable: dockerd
                      persists the subnet it first derived from the bridge, so changing
                      this value forces a libnetwork store reset for the daemon (done
                      automatically at start), which drops that daemon's docker networks.
                      Values 16..31 are disallowed as they fall inside 172.16.0.0/12,
                      which the firewall treats as LAN.
                    '';
                  };
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
        default = { };
        description = "Extra docker daemons to run.";
      };
    };
  };

  config =
    let
      cfg = config.virtualisation.docker;
      settingsFormatToml = pkgs.formats.toml { };
      settingsFormatJson = pkgs.formats.json { };
      daemons = lib.attrsets.attrValues config.setup.docker.extra-daemons;
    in
    {
      virtualisation.docker.enable = true;
      assertions = [
        {
          assertion =
            let
              octets = builtins.map (daemon: daemon.network.subnetOctet) daemons;
            in
            (builtins.length (lib.lists.unique octets)) == (builtins.length octets);
          message = "setup.docker.extra-daemons: each daemon's network.subnetOctet must be unique, otherwise the dockerd bridges would share a subnet and collide.";
        }
      ];
      environment.etc = lib.foldr (a: b: a // b) { } (
        builtins.map (
          daemon:
          let
            suffix = "-${daemon.name}";
            defaultConfig = (
              builtins.fromTOML (
                builtins.unsafeDiscardStringContext (
                  builtins.readFile "${pkgs.kata-runtime}/share/defaults/kata-containers/configuration.toml"
                )
              )
            );
          in
          lib.attrsets.optionalAttrs daemon.kata-runtime.enable {
            "docker-kata${suffix}/configuration.toml".source = (
              settingsFormatToml.generate "configuration${suffix}.toml" (
                defaultConfig
                // {
                  hypervisor.qemu = defaultConfig.hypervisor.qemu // {
                    default_vcpus = daemon.kata-runtime.cpus;
                    default_memory = daemon.kata-runtime.memory;
                  };
                }
              )
            );
          }
        ) daemons
      );
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
            daemonSettingsFile = settingsFormatJson.generate "daemon${suffix}.json" (
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
                features.time-namespaces = false; # todo: remove when kata-runtime releases this (greater than 3.31.0): https://github.com/kata-containers/kata-containers/issues/13080#issuecomment-4501602114
                runtimes = lib.attrsets.optionalAttrs daemon.kata-runtime.enable {
                  kata = {
                    runtimeType = "${pkgs.kata-runtime}/bin/containerd-shim-kata-v2";
                    options.ConfigPath = "/etc/docker-kata${suffix}/configuration.toml";
                  };
                };
              }
              // daemon.configuration
            );
            subnet = "172.${toString daemon.network.subnetOctet}.0.0/16";
            # dockerd derives (and then persists) the default bridge subnet from the
            # bridge interface's IP. If the configured subnet changes, the persisted
            # value would keep winning across restarts and reboots, so wipe the
            # libnetwork store when it no longer matches and let dockerd re-derive it.
            resetLibnetworkStore = pkgs.writeShellApplication {
              name = "docker${suffix}-reset-libnetwork-store";
              runtimeInputs = [ pkgs.coreutils ];
              text = ''
                stamp="${data-root}/.nixos-bridge-subnet"
                want="${subnet}"
                db="${data-root}/network/files/local-kv.db"
                if [ ! -f "$stamp" ] || [ "$(cat "$stamp")" != "$want" ]; then
                  echo "docker${suffix}: bridge subnet is now $want; resetting libnetwork store so dockerd re-derives it" >&2
                  rm -f "$db"
                  mkdir -p "$(dirname "$stamp")"
                  printf '%s' "$want" > "$stamp"
                fi
              '';
            };
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
                ExecStartPre = [ (lib.getExe resetLibnetworkStore) ];
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
                  configFile = settingsFormatToml.generate "containerd.toml" {
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
        ) daemons
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
        ) daemons
      );

      # New interface and bridge are required, with NAT, so network works as expected
      systemd.network.networks = lib.foldr (a: b: a // b) { } (
        builtins.map (daemon: {
          "40-${daemon.network.interfaceName}" = {
            networkConfig.ConfigureWithoutCarrier = "yes";
            linkConfig.RequiredForOnline = "no";
          };
        }) daemons
      );

      networking = {
        bridges = lib.foldr (a: b: a // b) { } (
          builtins.map (daemon: {
            "${daemon.network.interfaceName}" = {
              interfaces = [ ];
            };
          }) daemons
        );
        interfaces = lib.foldr (a: b: a // b) { } (
          builtins.map (daemon: {
            "${daemon.network.interfaceName}" = {
              ipv4.addresses = [
                {
                  address = "172.${toString daemon.network.subnetOctet}.0.1";
                  prefixLength = 16;
                }
              ];
              useDHCP = false;
            };
          }) daemons
        );
        nat = {
          enable = true;
          externalInterface = "eth0";
          internalInterfaces = builtins.map (daemon: daemon.network.interfaceName) daemons;
        };
        firewall =
          let
            extraCommands = builtins.concatStringsSep "\n" (
              builtins.map (
                daemon:
                let
                  dockerHostNetInterfaceName = daemon.network.interfaceName;
                in
                (builtins.concatStringsSep "\n" (
                  builtins.map (port: ''
                    # allowing port ${toString port} for docker daemon ${daemon.name} containers
                    iptables -I INPUT -i ${dockerHostNetInterfaceName} -p tcp --dport ${toString port} -j ACCEPT
                  '') daemon.network.disableICC.portExceptions
                ))
                + ''
                  # Disabling ICC (inter container communication) for docker daemon ${daemon.name} containers
                  iptables -A FORWARD -i ${dockerHostNetInterfaceName} -o ${dockerHostNetInterfaceName} -j DROP
                ''
              ) (builtins.filter (daemon: daemon.network.disableICC.enable) daemons)
            );
          in
          {
            inherit extraCommands;
            extraStopCommands = builtins.replaceStrings [ " -I " " -A " ] [ " -D " " -D " ] extraCommands;
          };
      };
    };
}
