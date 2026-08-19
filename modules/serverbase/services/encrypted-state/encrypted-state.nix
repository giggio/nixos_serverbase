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

  # The address `simulateKeyServerOutage` blocks, read out of the pin's own configuration rather than given as a
  # second option. A rehearsal that names the key server separately can drift from the one the machine actually
  # unlocks against, and then it proves nothing while looking like it passed.
  keyServerAddress =
    let
      url = (builtins.fromJSON cfg.clevisConfig).url or null;
      matched = if url == null then null else builtins.match "[a-z]+://([^:/]+).*" url;
    in
    if matched == null then null else builtins.head matched;

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
    # `cmp`, which is how the header backup is compared against the front of the container - by bytes, so the answer
    # is exact and costs no write.
    diffutils
    # For `encrypted-state-header-backup --export`. On the machine rather than on a workstation, because there is
    # no clean way to stream 16 MiB of root-owned key material off a server that asks for a sudo password.
    age
  ];

  scriptEnv = {
    IMAGE = cfg.image;
    MAPPER = cfg.mapperName;
    MOUNT_POINT = cfg.mountPoint;
    SIZE = cfg.size;
    PBKDF_MEMORY = toString cfg.pbkdfMemoryKiB;
    HEADER_BACKUP = cfg.headerBackupPath;
    HEADER_NOTIFY_UNITS = lib.concatStringsSep " " cfg.headerNotifyUnits;
    HEADER_EXPORT_RECIPIENTS = lib.concatStringsSep " " cfg.headerExportRecipients;
    CLEVIS_PIN = cfg.clevisPin;
    CLEVIS_CONFIG = cfg.clevisConfig;
    # init.sh needs it to decide whether finishing by starting encrypted-state.target is safe: with bindState
    # already true and a container that has never been migrated into, it is not.
    BIND_STATE = if cfg.bindState then "1" else "0";
    UNLOCK_ATTEMPT_TIMEOUT = toString cfg.unlockAttemptTimeoutSeconds;
    TARGET_UNIT = targetUnit;
    # /run, so a reboot starts the outage clock again: a machine that has just come back up into a dead key server
    # deserves its own notification rather than inheriting the silence of the one before it.
    OUTAGE_STAMP = "/run/encrypted-state-outage-since";
    OUTAGE_NOTIFIED = "/run/encrypted-state-outage-notified";
    OUTAGE_NOTIFY_AFTER = toString cfg.outageNotifyAfterSeconds;
    OUTAGE_NOTIFY_UNITS = lib.concatStringsSep " " cfg.outageNotifyUnits;
    # The drop-in `encrypted-state-migrate` leaves in /run/systemd/system/<unit>.d to keep a service off the empty
    # directory a moved path becomes, and that `encrypted-state-resume` removes once the path is really bound. `zz-`
    # so it sorts after anything else a unit may have picked up.
    GUARD_DROPIN = "zz-encrypted-state-migration.conf";
    RESUME_RESTART_UNITS = lib.concatStringsSep " " cfg.resumeRestartUnits;
    # Newline-separated rather than an array, because this crosses into shell as one environment variable.
    STATE_PATHS = lib.concatStringsSep "\n" (lib.attrNames cfg.paths);
    # One line per path: the path, a tab, then the units that read it. The migration needs both halves, and this is
    # the least fragile way to carry a small table through an environment variable.
    STATE_SPEC = lib.concatStringsSep "\n" (
      lib.mapAttrsToList (path: units: "${path}\t${lib.concatStringsSep " " units}") cfg.paths
    );
  };

  # `extra` is for the one script that drives another one. Keeping it out of `toolPath` is not tidiness: toolPath is
  # what every script is built with, so a script in there would have to be built with itself.
  mkScriptWith =
    extra: name: file:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = toolPath ++ extra;
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

  mkScript = mkScriptWith [ ];

  # The header backup belongs to creation, not to a checklist item the operator may or may not reach: the container
  # is bound and holding data from the moment init finishes, and that is already the moment its header matters.
  initScript = mkScriptWith [ headerBackupScript ] "encrypted-state-init" ./init.sh;
  unlockScript = mkScript "encrypted-state-unlock" ./unlock.sh;
  closeScript = mkScript "encrypted-state-close" ./close.sh;
  growScript = mkScript "encrypted-state-grow" ./grow.sh;
  migrateScript = mkScript "encrypted-state-migrate" ./migrate.sh;
  statusScript = mkScript "encrypted-state-status" ./status.sh;
  headerBackupScript = mkScript "encrypted-state-header-backup" ./header-backup.sh;
  headerCheckScript = mkScriptWith [ headerBackupScript ] "encrypted-state-header-check" ./header-check.sh;
  retryScript = mkScript "encrypted-state-retry" ./retry.sh;
  resumeScript = mkScript "encrypted-state-resume" ./resume.sh;
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

    headerBackupPath = mkOption {
      type = types.str;
      default = "/var/lib/encrypted-state-header.bak";
      description = ''
        Where `encrypted-state-header-backup` writes the container's LUKS2 header, and where
        `encrypted-state-status` looks for it.

        The header is the only single point of total loss in this design: damage anywhere else costs the sectors it
        touched, damage here costs every byte in the container, because the keyslots hold the master key. LUKS2's
        own second copy covers the binary header and not the keyslot area, so it does not cover this.

        **A local copy is half the answer.** It survives a botched `luksKillSlot` and a corrupted first 16 MiB; it
        does not survive the disk. The other half is copying it off the machine, which no module can do - see
        docs/encrypted-state.md. The default deliberately sits under /var/lib rather than beside the container, so
        on a machine whose container lives on separate storage the two are already on different devices.

        Treat the file as key material: it holds the same keyslots the container does.
      '';
    };

    headerNotifyUnits = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "notify_telegram@encrypted-state-header-check.service" ];
      description = ''
        Units started by `encrypted-state-header-check.service` when the header backup has gone stale or missing.
        Same shape as `outageNotifyUnits`, and normally the same notifier with this unit as the instance - so the
        message carries this check's own explanation rather than the unlock unit's.

        Why this exists at all: the honest answer to "when must the backup be re-taken?" is "after `luksAddKey`,
        `luksKillSlot`, `luksChangeKey`, `clevis luks bind` or `clevis luks unbind`" - five commands run once every
        few years. Nobody remembers that. A stale backup is silent, still looks like protection, and is discovered
        while trying to use it.

        Unlike `outageNotifyUnits` this fires every day until it is fixed. An outage ends on its own; this does not.
      '';
    };

    headerExportRecipients = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "age1..." ];
      description = ''
        age recipients for `encrypted-state-header-backup --export`, which writes an encrypted copy of the header
        backup to hand to whatever carries it off the machine.

        Declared here rather than typed at the prompt for two reasons. A recipient mistyped at 11pm produces a file
        that looks fine and opens for nobody, and it is only discovered during a recovery. And the person doing
        this in two years should not have to work out which keys were the right ones - `nixos-rebuild` has already
        answered that.

        **Use more than one.** The two situations that need this file are a header damaged on a machine that is
        otherwise healthy, and a machine that no longer exists; the key that is reachable differs between them.
      '';
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

    retryIntervalSeconds = mkOption {
      type = types.ints.positive;
      default = 300;
      description = ''
        How often `encrypted-state-retry.timer` tries again while the container is down.

        Deliberately not short. Each tick starts the unlock, which clears its `failed` state for as long as the
        attempt runs - and that failed state is the only thing `systemctl --failed` and `is-system-running` have to
        go on. Retrying every few seconds would hide the outage all over again, in a new way. The first tick after
        boot is a minute, which covers the ordinary case of this machine booting before the key server does.
      '';
    };

    outageNotifyAfterSeconds = mkOption {
      type = types.ints.positive;
      default = 600;
      description = ''
        How long the container must have been unavailable before `outageNotifyUnits` are started. Long enough that
        a power cut, where this machine and the key server come back at their own paces, does not page anyone.
      '';
    };

    resumeRestartUnits = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "systemd_traefik_configuration_provider.service" ];
      description = ''
        Units to restart after this module has started the guarded services itself — at the end of a heal, or when
        the second deploy releases the migration guards.

        For things that derive their configuration from what is *currently* running rather than from what exists.
        A reverse proxy built that way has no route for a service that came up outside the ordering it watches, and
        the symptom is one service missing from the proxy while everything else works — which reads as a fault in
        that service.

        Empty by default: whether a machine has anything of this shape is the machine's business, not this
        module's.
      '';
    };

    outageNotifyUnits = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "notify_telegram@encrypted-state.service" ];
      description = ''
        Units to start once the container has been down for `outageNotifyAfterSeconds`, exactly once per outage.

        Empty by default because how a machine reaches its owner is the business of whichever repository owns the
        machine, not of this module. Without it the outage is still visible - the unlock unit sits in `failed` and
        `encrypted-state-status` exits non-zero - but nothing goes looking for you.
      '';
    };

    unlockAttemptTimeoutSeconds = mkOption {
      type = types.ints.positive;
      default = 60;
      description = ''
        How long the unlock may take before it is killed and counted as failed. A key server that is switched off
        drops packets rather than refusing them, so the connect inside clevis hangs; without a bound here the unit
        sits in `activating` for as long as the kernel keeps retrying the SYN, which is the state the whole design
        is arranged to avoid - it is what `nixos-rebuild switch` waits on, and what hides the outage from
        `systemctl --failed`.
      '';
    };

    simulateKeyServerOutage = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Rehearse the degrade case: silently drop everything this machine sends to the key server named in
        `clevisConfig`, so it boots exactly as it would with that server dead.

        DROP rather than reject, and a firewall rule rather than a blackhole route, because the two fail
        differently and only one of them is the case worth rehearsing. A route - or a rejection - fails
        immediately, which the unlock handles trivially. A server that is simply off gives silent drops and a TCP
        connect that hangs until the kernel gives up, and it is the waiting that can drag the boot: that is what
        `DefaultDependencies=no` on every unit here exists to survive.

        It also survives a reboot, which is the point. Nothing typed at a shell does - a route is gone on the next
        boot, and NixOS keeps `/etc/systemd/system` in the store, so there is nowhere to persist one by hand.

        Lift it without a rebuild to watch `encrypted-state-retry` heal the machine on its own:
        `iptables -D OUTPUT -d <address> -j DROP`.

        VMs and test nodes only, asserted. On a real machine this is an outage.

        The checks do not use it: a nixosTest can shut the fixture key server down, which is the same silent drop
        without a rule to install. This exists for the case a test cannot reach - a VM booting against the real key
        server, where the only thing that can be taken away is this machine's route to it.
      '';
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
        # The only guard between a rehearsal and an outage. Everything else about this option is recoverable by
        # deleting one iptables rule; enabling it on a real machine takes its databases down until someone notices.
        assertion = !cfg.simulateKeyServerOutage || config.setup.isVM || config.setup.isTest;
        message = "setup.encryptedState.simulateKeyServerOutage cuts the machine off from its key server. It is for VMs and test nodes only.";
      }
      {
        assertion = !cfg.simulateKeyServerOutage || !config.networking.nftables.enable;
        message = "setup.encryptedState.simulateKeyServerOutage installs an iptables rule, which networking.nftables.enable ignores.";
      }
      {
        # Silently blocking nothing is the failure that would matter here: the rehearsal reaches the key server,
        # everything unlocks, and the degrade case reads as passed.
        assertion = !cfg.simulateKeyServerOutage || keyServerAddress != null;
        message = "setup.encryptedState.simulateKeyServerOutage needs a `url` in clevisConfig to know what to block.";
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
        # The same circularity, and worse: a header backup reachable only by opening the container it exists to
        # reopen is not a backup. It would also be inside the encryption, so a recovery could not read it without
        # the key it is there to supply.
        assertion = !(lib.hasPrefix cfg.mountPoint cfg.headerBackupPath);
        message = "setup.encryptedState.headerBackupPath cannot live inside setup.encryptedState.mountPoint - the container would have to be open to read the backup that reopens it.";
      }
      {
        assertion = cfg.headerBackupPath != cfg.image;
        message = "setup.encryptedState.headerBackupPath must not be setup.encryptedState.image; writing the header backup over the container would destroy it.";
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

    # OUTPUT rather than INPUT: the point is that this machine cannot reach the key server, not that some packet
    # cannot reach this machine. The stop command keeps `systemctl restart firewall` from stacking duplicates.
    networking.firewall = lib.mkIf cfg.simulateKeyServerOutage {
      extraCommands = "iptables -I OUTPUT -d ${keyServerAddress} -j DROP";
      extraStopCommands = "iptables -D OUTPUT -d ${keyServerAddress} -j DROP || true";
    };

    environment.systemPackages = [
      initScript
      growScript
      migrateScript
      closeScript
      statusScript
      headerBackupScript
      pkgs.cryptsetup # so `luksDump`, `token export` and friends are at hand on a machine that has to be recovered
    ];

    # Always running, not started by the unlock's OnFailure=, so that a container which goes away *after* boot -
    # the key server rebooted, the LAN blipped, someone ran encrypted-state-close - is picked up too. The script is
    # a no-op when the container is mounted or has never been created, so a tick costs nothing.
    systemd.timers.encrypted-state-retry = {
      description = "Retry the application state container unlock, and alert if it stays down";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # The first tick is short so the ordinary case - this machine booted before the key server did - heals in
        # about a minute. After that the interval is long, because a slow drum of retries during a real outage buys
        # nothing and each tick briefly clears the `failed` state that is the machine's only visible symptom.
        OnBootSec = "1min";
        OnUnitInactiveSec = cfg.retryIntervalSeconds;
        AccuracySec = "10s";
      };
    };

    # Daily, and Persistent so a machine that is off overnight still gets asked rather than skipping the day. Cheap:
    # it reads 16 MiB and compares, which is why it can afford to run unconditionally instead of trying to detect
    # the five commands that would have invalidated the backup.
    systemd.timers.encrypted-state-header-check = {
      description = "Daily check that the LUKS header backup is still current";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
        # Nothing here is urgent to the minute, and a fixed time would put this in the same second as every other
        # daily job on the machine.
        RandomizedDelaySec = "1h";
      };
    };

    systemd.targets.encrypted-state = {
      description = "Application state held in the unlocked LUKS container";
      wantedBy = [ "multi-user.target" ];
    };

    systemd.services = lib.mkMerge [
      {
        encrypted-state-unlock = {
          description = "Unlock the application state container";
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
            # One bounded attempt plus room for argon2id, and nothing else. This unit must fail FAST: everything
            # that reports the outage keys on it having failed, and `nixos-rebuild switch` waits on its start job.
            TimeoutStartSec = cfg.unlockAttemptTimeoutSeconds + 120;
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

        # The other end of the migration window. `encrypted-state-migrate` masks each path's units as it moves the
        # data out, because between that move and this deploy the path is an empty directory with no mount over it
        # and no guard on it - and a database that starts there initialises a new one. This lifts the masks once the
        # bind mounts are actually up, so masked ends exactly where guarded begins.
        encrypted-state-resume = lib.mkIf (cfg.bindState && cfg.paths != { }) {
          description = "Release the units the migration masked, now that their paths are bound";
          after = [ containerMountUnit ] ++ bindMountUnits;
          requires = [ containerMountUnit ];
          wantedBy = [ targetUnit ];
          partOf = [ targetUnit ];
          unitConfig.DefaultDependencies = "no";
          path = toolPath;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${resumeScript}/bin/encrypted-state-resume";
          };
        };

        # Healing loop for the case that matters: the machine booted faster than the router, the key server was
        # unreachable, and the unlock failed. Without this the databases stay down until a human intervenes.
        #
        # A TIMER drives this, not `Restart=` on the unlock unit, and that is the whole point of the shape. Anything
        # that restarts the unlock keeps it `activating`, and an `activating` unit is invisible: no `--failed` entry,
        # no `degraded`, no OnFailure=, and a `nixos-rebuild switch` that waits out the retry budget. Leaving the
        # unlock in `failed` between ticks is what makes the machine honest about its state; this unit is what makes
        # it heal anyway.
        encrypted-state-retry = {
          description = "Retry the application state container unlock";
          # Nothing in the default graph: this must be able to run while the machine sits degraded, and it must not
          # drag anything else into waiting on a box on the LAN. Same reasoning as the unlock unit above.
          unitConfig.DefaultDependencies = "no";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          path = toolPath;
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${retryScript}/bin/encrypted-state-retry";
            # It starts the target, which starts the unlock, which is bounded by unlockAttemptTimeoutSeconds. Room
            # for that plus the mounts, and no more: a retry that outlives its own interval would stack.
            TimeoutStartSec = cfg.unlockAttemptTimeoutSeconds + 120;
          };
        };

        # The header backup's own alarm. Everything else in this module reports availability; this reports the one
        # thing whose failure is not an outage but a total loss, and which is otherwise completely silent.
        encrypted-state-header-check = {
          description = "Check that the LUKS header backup still matches the container";
          # Reads two files. It does not touch the container, does not need it unlocked, and must run on a machine
          # that is sitting degraded - a stale backup during an outage is worse, not less relevant.
          unitConfig.DefaultDependencies = "no";
          path = toolPath;
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${headerCheckScript}/bin/encrypted-state-header-check";
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
