{
  config,
  lib,
  pkgs,
  utils,
  helpers,
  ...
}:

# A LUKS2 container in a FILE on the root filesystem, keyed by a clevis pin, with the declared paths bind-mounted
# out of it onto the locations the services already use.
#
# WHAT IT IS FOR AND HOW IT IS OPERATED: docs/encrypted-state.md. That covers why a file rather than a partition,
# why disko is not involved, the failure mode the hard dependencies exist to prevent, and the two shapes that must
# not go in the container.
#
# WHAT A READER OF THIS FILE HAS TO KNOW: every unit here is `DefaultDependencies=no`, and that is load-bearing
# rather than tidy. Take it off and the machine still boots, still looks fine, and has silently dropped a job or
# made sshd wait on a box on the LAN. Neither is visible in a unit file, which is why both checks assert the boot
# journal contains no ordering cycle. The comments at each declaration say what that particular one is holding up.

let
  cfg = config.setup.encryptedState;

  mapperDevice = "/dev/mapper/${cfg.mapperName}";
  unlockUnit = "encrypted-state-unlock.service";
  targetUnit = "encrypted-state.target";
  containerMountUnit = "${utils.escapeSystemdPath cfg.mountPoint}.mount";
  bindMountUnits = lib.map (path: "${utils.escapeSystemdPath path}.mount") (lib.attrNames cfg.paths);

  # The container mirrors the real tree: /var/lib/foo lives at <mountPoint>/var/lib/foo. Costs a string
  # concatenation, and means anyone who opens the container by hand during a recovery recognises what they are
  # looking at instead of decoding a flattened name. It also makes collisions structurally impossible, which a
  # flattened scheme would not.
  containerPathOf = path: "${cfg.mountPoint}${path}";

  # Everything the scripts below reach for. `clevis` is NOT self-contained - `clevis luks unlock` shells out to a
  # per-pin helper, which for the tang pin needs `curl` to reach the server and `jose` to do the JWE work - so all
  # three have to be here. That was found the hard way once already; see modules/helpers/clevis.nix.
  toolPath = with pkgs; [
    clevis
    jose
    curl
    cryptsetup
    util-linux
    coreutils
    gnused
    gnugrep
    e2fsprogs
    rsync
    systemd
  ];

  scriptEnv = {
    IMAGE = cfg.image;
    MAPPER = cfg.mapperName;
    MOUNT_POINT = cfg.mountPoint;
    SIZE = cfg.size;
    PBKDF_MEMORY = toString cfg.pbkdfMemoryKiB;
    CLEVIS_PIN = cfg.clevisPin;
    CLEVIS_CONFIG = cfg.clevisConfig;
    # init.sh needs it to decide whether finishing by starting encrypted-state.target is safe: with bindState
    # already true and a container that has never been migrated into, it is not.
    BIND_STATE = if cfg.bindState then "1" else "0";
    UNLOCK_ATTEMPTS = toString cfg.unlockAttempts;
    UNLOCK_DELAY = toString cfg.unlockDelaySeconds;
    # Newline-separated rather than an array, because this crosses into shell as one environment variable.
    STATE_PATHS = lib.concatStringsSep "\n" (lib.attrNames cfg.paths);
    # One line per path: the path, a tab, then the units that read it. The migration needs both halves, and this is
    # the least fragile way to carry a small table through an environment variable.
    STATE_SPEC = lib.concatStringsSep "\n" (
      lib.mapAttrsToList (path: units: "${path}\t${lib.concatStringsSep " " units}") cfg.paths
    );
  };

  mkScript =
    name: file:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = toolPath;
      text = ''
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}") scriptEnv
        )}
        ${builtins.readFile file}
      '';
    };

  # Every unit named across all the declared paths, and the ones the machine has no definition for. Read off
  # `config.systemd.services` rather than off the generated units, so this stays an evaluation-time question.
  declaredUnits = lib.unique (lib.flatten (lib.attrValues cfg.paths));
  unknownUnits = lib.filter (
    unit: !(lib.hasAttr (lib.removeSuffix ".service" unit) config.systemd.services)
  ) (lib.filter (lib.hasSuffix ".service") declaredUnits);

  initScript = mkScript "encrypted-state-init" ./init.sh;
  unlockScript = mkScript "encrypted-state-unlock" ./unlock.sh;
  closeScript = mkScript "encrypted-state-close" ./close.sh;
  growScript = mkScript "encrypted-state-grow" ./grow.sh;
  migrateScript = mkScript "encrypted-state-migrate" ./migrate.sh;
in
{
  options.setup.encryptedState = with lib; {
    enable = mkEnableOption "a clevis-unlocked LUKS container for application state";

    bindState = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to bind the declared paths out of the container onto their real locations.

        The migration hatch, and why the default is `false`: turning this on before `encrypted-state-migrate` has
        run would mount empty directories over live data. Once a machine has migrated it stays `true` forever. The
        two-deploy sequence is in docs/encrypted-state.md.
      '';
    };

    image = mkOption {
      type = types.str;
      default = "/var/lib/encrypted-state.img";
      description = "The container file. Must live on a filesystem that supports fallocate; ext4 does.";
    };

    mapperName = mkOption {
      type = types.str;
      default = "encrypted-state";
      description = "Name of the device-mapper node, so the container appears at /dev/mapper/<this>.";
    };

    mountPoint = mkOption {
      type = types.str;
      default = "/encrypted";
      description = "Where the container's filesystem is mounted. The declared paths are bound out of it.";
    };

    size = mkOption {
      type = types.str;
      example = "64G";
      description = ''
        Size of the container, in `fallocate -l` syntax. **Allocated in full, not sparse**, so this much disk goes
        the moment `encrypted-state-init` runs and the machine must have it free.

        Undersizing is cheap to fix - `encrypted-state-grow` is online and touches no partition table - so prefer a
        size that fits comfortably today over one that guesses at years of growth.
      '';
    };

    pbkdfMemoryKiB = mkOption {
      type = types.ints.positive;
      default = 262144; # 256 MiB
      description = ''
        `--pbkdf-memory` for argon2id, in KiB, pinned rather than left to cryptsetup's self-calibration - which
        measures free memory at FORMAT time on an idle box, while unlocking happens on a busy one. Lower it only
        for a test VM; see docs/encrypted-state.md.
      '';
    };

    clevisPin = mkOption {
      type = types.str;
      default = "tang";
      example = "tpm2";
      description = ''
        The clevis pin used to bind the container's keyslot. Any pin clevis supports works here - the module only
        ever hands this and `clevisConfig` to `clevis luks bind` and lets clevis do the rest.
      '';
    };

    clevisConfig = mkOption {
      type = types.str;
      example = ''{"url":"http://10.0.0.1:7500","thp":"..."}'';
      description = ''
        JSON configuration for the pin, passed to `clevis luks bind`. Its shape is the pin's business.

        PIN THE KEY. A network pin given an address alone trusts whatever answers, so anything that can win a race
        on the LAN becomes the key server. Deliberately not defaulted: it is site-specific, and the machine it
        points at belongs to whichever repository owns the machine, not to this one.
      '';
    };

    unlockAttempts = mkOption {
      type = types.ints.positive;
      default = 20;
      description = ''
        How many times to try the pin before giving up. Generous, because this runs at boot: a network pin's key
        server may be a small box on wifi, and the router it depends on may still be coming up. Giving up too early
        turns a slow start into a machine whose databases are down.
      '';
    };

    unlockDelaySeconds = mkOption {
      type = types.ints.positive;
      default = 15;
      description = "Seconds between unlock attempts.";
    };

    paths = mkOption {
      default = { };
      description = ''
        Application state directories to hold inside the container: the real absolute path, and the units that read
        or write it. Each unit named gets a hard dependency on the bind mount, so it cannot start while the
        container is locked.

        Name every unit that reads the LIVE directory, including `-setup` and backup ones - and only those. Both
        mistakes cost something, and docs/encrypted-state.md says what.

        An ordinary attribute set, so it merges as NixOS options do: declare each path in the module that defines
        its units, and several modules may name the same path - the lists concatenate.
      '';
      example = literalExpression ''
        {
          "/var/lib/mything" = [ "mything.service" "mything-setup.service" ];
        }
      '';
      type = types.attrsOf (types.listOf types.str);
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.clevisConfig != "";
        message = "setup.encryptedState.clevisConfig must configure the pin; without it the container cannot be bound or unlocked.";
      }
      {
        assertion = cfg.size != "";
        message = "setup.encryptedState.size must be set.";
      }
      {
        assertion = lib.all (p: lib.hasPrefix "/" p) (lib.attrNames cfg.paths);
        message = "setup.encryptedState.paths must be keyed by absolute paths.";
      }
      {
        # A path inside another declared path would be bound twice, and the inner bind would be shadowed or
        # unshadowed depending on mount order - which is not something to discover in production.
        assertion =
          let
            paths = lib.attrNames cfg.paths;
          in
          lib.all (a: lib.all (b: a == b || !(lib.hasPrefix "${b}/" a)) paths) paths;
        message = "setup.encryptedState.paths must not nest inside one another; declare the outer path only.";
      }
      {
        assertion = !(lib.hasPrefix cfg.mountPoint cfg.image);
        message = "setup.encryptedState.image cannot live inside setup.encryptedState.mountPoint - the container would have to be mounted to be found.";
      }
      {
        # A misspelled unit name is the most dangerous mistake available here, and the quietest: the guard is simply
        # attached to a unit that does not exist, the real one keeps its default ordering, and the first time the
        # container fails to unlock that service starts against an empty directory and initialises itself. Nothing
        # warns, because asking systemd to order a nonexistent unit is not an error. Checking the names against the
        # machine's own service set turns it into an evaluation failure instead - which `make eval` catches on the
        # commit that introduces it.
        #
        # PROD ONLY, because a dev VM and a test node are built with whole categories of unit deliberately removed -
        # every backup job, for one - so there a missing name is the environment working as intended and says
        # nothing about the spelling. The production configuration of every machine is evaluated by `make eval` on
        # every push, so gating on this costs no coverage where it matters and stops the check from crying wolf on
        # the two environments that exist to be smaller.
        assertion = !config.setup.isProd || unknownUnits == [ ];
        message =
          "setup.encryptedState.paths names units this machine does not define: "
          + lib.concatStringsSep ", " unknownUnits
          + ". A guard attached to a unit that does not exist protects nothing, so check the spelling "
          + "(names here include the .service suffix; systemd.services keys do not).";
      }
    ];

    environment.systemPackages = [
      initScript
      growScript
      migrateScript
      closeScript
      pkgs.cryptsetup # so `luksDump`, `token export` and friends are at hand on a machine that has to be recovered
    ];

    systemd.targets.encrypted-state = {
      description = "Application state held in the unlocked LUKS container";
      wantedBy = [ "multi-user.target" ];
    };

    systemd.services = lib.mkMerge [
      {
        encrypted-state-unlock = {
          description = "Unlock the application state container";
          onFailure = [ "encrypted-state-retry.service" ];
          # network-online rather than network.target: a network pin needs to actually reach a box on the LAN, not
          # merely to have had interfaces configured.
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];
          before = [
            targetUnit
            "umount.target"
          ];
          conflicts = [ "umount.target" ];
          wantedBy = [ targetUnit ];
          unitConfig = {
            # DefaultDependencies=no, and this is the load-bearing half of keeping the machine bootable when the key
            # server is down.
            #
            # An ordinary service is `After=basic.target`, and basic.target pulls in sockets.target and paths.target.
            # Anything ordered after one of this container's mounts therefore reaches back to those targets, and
            # since the mounts wait on a box on the LAN, the whole early graph ends up waiting with them - in
            # practice that has been a `.path` unit watching a file inside a bound path, dragging paths.target, and
            # a socket unit dragging sockets.target. Either closes an ordering cycle, which systemd resolves by
            # DELETING a job; and even where it does not, it means basic.target - and therefore sshd - waits out
            # the unlock retries before the machine finishes booting. A server whose key server is dead must come up
            # promptly with its databases down, not slowly with everything down.
            #
            # So this is taken out of the default graph and given only what it actually needs: the filesystem
            # holding the container, and the network.
            DefaultDependencies = "no";
            RequiresMountsFor = [ (builtins.dirOf cfg.image) ];
            # Infinite retries, the same shape as a network mount: a key server that comes up late must heal itself
            # rather than leave the databases down until someone notices.
            StartLimitIntervalSec = "0";
          };
          path = toolPath;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${unlockScript}/bin/encrypted-state-unlock";
            ExecStop = "${closeScript}/bin/encrypted-state-close";
            # The retry loop inside the script can run for unlockAttempts * unlockDelaySeconds, so the unit must be
            # allowed at least that long plus room for argon2id.
            TimeoutStartSec = cfg.unlockAttempts * cfg.unlockDelaySeconds + 120;
          };
        };

        # systemd-tmpfiles-setup runs at sysinit, long before anything here is mounted, so every tmpfiles rule
        # pointing at a path INSIDE the container applied to the mountpoint and was then hidden by the mount - the
        # ownership and modes of exactly the directories the services are about to use. Re-running it once the
        # mounts are up is idempotent - it is the same thing nixos-rebuild does at activation - and it is the only
        # way those rules ever reach the filesystem they were written for.
        encrypted-state-tmpfiles = lib.mkIf (cfg.bindState && cfg.paths != { }) {
          description = "Apply tmpfiles rules to paths that only exist once the container is mounted";
          after = [ containerMountUnit ] ++ bindMountUnits;
          requires = [ containerMountUnit ];
          wantedBy = [ targetUnit ];
          partOf = [ targetUnit ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            # --create only. Not --remove, which acts on `r`/`R` rules and would delete things, and not --boot,
            # whose `!` rules are written on the assumption that nothing is running yet.
            #
            # ONE --prefix PER DECLARED PATH, and without them this unit fails. A bare `--create` re-applies the
            # machine's ENTIRE ruleset, and a rule that was fine at sysinit is not necessarily fine now: the whole
            # reason this unit exists is that the filesystem changed underneath it. Two real examples, both from
            # the first rehearsal:
            #
            #   fchownat() of /var/lib/nextcloud/data failed: Invalid argument
            #       - a network mount, absent at sysinit when the rule chowned an empty local directory, and
            #         present now, where the server rejects the chown.
            #   "/etc/authelia/main/config" already exists and is not a directory
            #       - did not exist at sysinit; a service has since put something else there.
            #
            # Neither has anything to do with this container, and neither is fixable from here. systemd-tmpfiles
            # keeps going after a failed line but exits 73, so the unit went red on every boot while doing its job
            # perfectly well - which is worse than useless, because a permanently failed unit is one nobody reads.
            #
            # Restricting to the declared paths says what was always meant: re-apply the rules for the directories
            # that only came into existence when the container was mounted.
            ExecStart = "${pkgs.systemd}/bin/systemd-tmpfiles --create ${
              lib.concatMapStringsSep " " (path: "--prefix=${path}") (lib.attrNames cfg.paths)
            }";
          };
        };

        # Healing loop for the case that matters: the machine booted faster than the router, the key server was
        # unreachable, and the unlock failed. Without this the databases stay down until a human intervenes.
        encrypted-state-retry = {
          description = "Retry the application state container unlock";
          unitConfig = {
            StartLimitIntervalSec = "0";
            # Nothing to retry if the container has never been created, and that is not a hypothetical state - it is
            # exactly where a machine sits between the first deploy and `encrypted-state-init`. Without this the
            # retry loop would spin every thirty seconds through what may be a long coffee break, filling the
            # journal with a failure whose cause is "you have not run the next step yet". A missing container is an
            # operator action, not a transient fault; an unreachable key server is the transient fault this exists
            # for. The condition is re-evaluated on every restart, so the loop starts working the moment the
            # container appears.
            ConditionPathExists = cfg.image;
          };
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.systemd}/bin/systemctl start ${targetUnit}";
            RemainAfterExit = false;
            Restart = "on-failure";
            RestartSec = "30s";
            RestartMaxDelaySec = "5m";
            RestartSteps = "4";
          };
        };
      }

      # The other half of the guard, on the consuming units themselves. RequiresMountsFor is what stops the unit
      # starting at all; checkMountScript is what catches the case RequiresMountsFor cannot see - a mount unit that
      # reports success but whose filesystem is wedged, which on a loop-backed device is a real possibility.
      (lib.mkIf cfg.bindState (
        lib.mkMerge (
          lib.flatten (
            lib.mapAttrsToList (
              path: units:
              lib.map (unit: {
                ${lib.removeSuffix ".service" unit} = {
                  # A LIST, not a bare string, and that is load-bearing. Upstream modules set this too - nixpkgs'
                  # postgresql module already asks for its own data directory - and NixOS merges a systemd unit
                  # option by equality unless at least one definition is a list, in which case every definition is
                  # concatenated. A string here is an evaluation conflict with any module that got there first;
                  # a list makes both requirements hold, which is what systemd wants anyway (RequiresMountsFor
                  # accepts repeated assignments and unions them).
                  unitConfig.RequiresMountsFor = [ path ];
                  preStart = lib.mkBefore (helpers.systemd.checkMountScript [ path ]);
                };
              }) (lib.filter (lib.hasSuffix ".service") units)
            ) cfg.paths
          )
        )
      ))
    ];

    # `systemd.mounts` rather than `fileSystems`, for two reasons. The dependencies here are real unit dependencies -
    # this mount waits on a service that talks to a box on the LAN - and expressing that as `x-systemd.*` strings
    # inside an fstab options list is a way to get it silently wrong. And `fileSystems` is what NixOS turns into
    # /etc/fstab for the machine's REAL disks, which a test VM overrides wholesale (`mkVMOverride`) to describe its
    # own; a container that only exists after boot has no business in that list, and putting it there means it
    # disappears in exactly the environment meant to prove it works.
    # DefaultDependencies=no on every mount here, and it is not an optimisation - without it the system does not
    # boot correctly and does not say so.
    #
    # A mount unit under / gets `Before=local-fs.target` by default. This one also requires a service that talks to
    # the network, and every ordinary service is `After=basic.target`, which is after sysinit.target, which is after
    # systemd-tmpfiles-setup.service, which is after local-fs.target. That closes a loop, and systemd's response to
    # an ordering cycle is to DELETE one of the jobs in it and carry on booting. It picked
    # systemd-tmpfiles-setup.service - so every tmpfiles rule on the machine silently did not run. The only trace is
    # one line in the journal at boot.
    #
    # So these mounts are taken out of the default web entirely and given exactly the ordering they need: after the
    # real filesystems, before the container's own target, and - since DefaultDependencies=no also drops the
    # shutdown half - explicitly stopped before umount.target, so the loop device is detached while the root
    # filesystem is still writable.
    systemd.mounts = [
      {
        what = mapperDevice;
        where = cfg.mountPoint;
        type = "ext4";
        conflicts = [ "umount.target" ];
        # `nodiscard`, and no allow-discards on the crypt device either. Discards from inside the container would
        # travel down through dm-crypt and the loop device and punch holes in the backing FILE, quietly turning the
        # fully-allocated container back into a sparse one - which is the exact failure the `size` option warns
        # about. The outer filesystem trims the file's extents on its own schedule.
        options = "nodiscard";
        unitConfig = {
          DefaultDependencies = "no";
          # The directory holding the container file, and deliberately NOT `After=local-fs.target`. The precise
          # dependency is the one filesystem the container file lives on - the root, mounted in the initrd.
          # Ordering after local-fs.target instead would be both vaguer and actively wrong: local-fs.target is
          # ordered after every ordinary mount, including any nested INSIDE a path this container binds, and those
          # would then be waiting on a mount that is waiting on local-fs.target.
          RequiresMountsFor = [ (builtins.dirOf cfg.image) ];
        };
        # Not wanted by local-fs.target, which is ordered before the network exists. This mount cannot succeed until
        # the pin has answered, so it hangs off its own target instead.
        requires = [ unlockUnit ];
        after = [ unlockUnit ];
        wantedBy = [ targetUnit ];
        before = [
          targetUnit
          "umount.target"
        ];
      }
    ]
    ++ lib.optionals cfg.bindState (
      lib.mapAttrsToList (path: _: {
        what = containerPathOf path;
        where = path;
        type = "none";
        options = "bind";
        unitConfig.DefaultDependencies = "no";
        conflicts = [ "umount.target" ];
        # Requires= plus After= on the container's own mount unit. A path bound out of a container that is not there
        # must fail, not quietly succeed against the empty directory underneath it.
        requires = [ containerMountUnit ];
        after = [ containerMountUnit ];
        wantedBy = [ targetUnit ];
        before = [
          targetUnit
          "umount.target"
        ];
      }) cfg.paths
    );
  };
}
