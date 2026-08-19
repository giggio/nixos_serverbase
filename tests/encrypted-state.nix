{
  pkgs,
  testNodes,
  ...
}:

# Covers modules/serverbase/services/encrypted-state - the clevis-unlocked LUKS container that application state is
# bind-mounted out of, and the init/migrate/grow scripts that manage it.
#
# The subtest that justifies the whole file is "a locked container keeps the service DOWN". Everything else here is
# ordinary plumbing that would be caught the first time someone looked; that one is not - see the failure mode in
# docs/encrypted-state.md. `testapp` below is written to behave exactly that badly on purpose (finds no data,
# creates some, calls it success), and the test asserts it never gets the chance.
#
# The module takes any clevis pin; the fixture uses the tang one because it is the only pin that can be stood up
# inside a test VM - a tpm2 pin would need a TPM and an sss pin is a composition of the others. That costs nothing,
# for the same reason as tests/clevis-unlock.nix: tang is a stateless protocol and every part that can break lives
# on the client side, which is all this module is.
#
# Not covered here, deliberately: key pinning. There is one key server in this test and the test creates it, so
# pinning its own thumbprint would assert nothing. That belongs to whichever repository owns a real key server, and
# has to be checked against the real one to mean anything.

let
  tangPort = 7500;
  image = "/var/lib/encrypted-state.img";
  # The module's default for headerBackupPath, spelled out rather than read from the option, so that changing the
  # default has to come past this test instead of quietly taking it along.
  headerBackup = "/var/lib/encrypted-state-header.bak";

  # A throwaway age identity, generated for this file and used nowhere else. The point of having the private half
  # here is that the exported copy gets DECRYPTED and compared against the original - "a file was produced" is not
  # the property under test, "the file opens for the configured recipient and is byte-identical" is. That is the
  # failure this catches: a mistyped recipient produces a perfectly good file that opens for nobody, and the only
  # moment anyone finds out is during a recovery.
  testAgeRecipient = "age16sfgdqg7695kwu208q8tcuzg5jhy2e75kpld32mghwrra2gk9e5qfqh75h";
  testAgeIdentity = "AGE-SECRET-KEY-1QUWJ72SG57XHU4A9VA6PSSMK8ZXVLJEF555Y8EWWCTVFSV9N9M9QXEHLX9";
  identityFile = "/run/test-age-identity";
  mountPoint = "/encrypted";
  statePath = "/var/lib/testapp";
  passphraseFile = "/run/test-recovery-passphrase";
  passphrase = "test-recovery-passphrase-not-a-real-one";
  initialSize = "256M";
  grownSize = "512M";
  # systemd's name for the container's own mount unit. The test has to start it on its own, without the target that
  # would also pull in the bind mounts: binding the container's still-empty directories over the seeded state before
  # the migration would hide the very data the migration is supposed to copy. Spelled out rather than computed,
  # because a helper that derived it the same way the module does would agree with the module by construction and
  # prove nothing about the name systemd actually picked.
  containerMountUnit = "encrypted.mount";

  # Both client nodes, differing only in `bindState` - which is the one thing that differs between the two deploys
  # of a real migration, and cannot be changed mid-test because a nixosTest node has exactly one configuration.
  mkNode =
    { hostName, bindState }:
    { nodes, lib, ... }:
    {
      imports = [ testNodes.base ];
      setup = {
        inherit hostName;
        username = "giggio";
        encryptedState = {
          enable = true;
          inherit bindState image mountPoint;
          size = initialSize;
          # 32 MiB rather than the 256 MiB default. argon2id allocates this for real, twice per test run, on a node
          # with 1 GiB - and what is being tested is the plumbing around the KDF, not the KDF.
          pbkdfMemoryKiB = 32768;
          clevisConfig = builtins.toJSON {
            url = "http://${nodes.tang.networking.primaryIPAddress}:${toString tangPort}";
          };
          # Short, so the negative case fails inside the test's patience rather than at the driver's timeout.
          unlockAttemptTimeoutSeconds = 20;
          # Alerting, wired to a unit that only leaves a file behind. Zero grace would be untestable in the other
          # direction, so this is one second: long enough to be a real comparison, short enough to have passed.
          outageNotifyAfterSeconds = 1;
          outageNotifyUnits = [ "fake-notify.service" ];
          headerNotifyUnits = [ "fake-header-notify.service" ];
          # A throwaway age identity generated for this file, so the export can be decrypted back and compared
          # rather than merely produced. Its private half is below; it protects nothing.
          headerExportRecipients = [ testAgeRecipient ];
          paths."${statePath}" = [ "testapp.service" ];
        };
      };

      # Room for the container plus the grown container plus the pre-migration copy.
      virtualisation.diskSize = 4096;

      # Stands in for a database server, and specifically for the thing that makes one dangerous: finding no data,
      # it creates some and calls that success. If this ever writes FRESH-INIT after the guard is in place, the
      # guard has failed and a real database would have been silently replaced.
      systemd.services.testapp = {
        description = "a service that quietly reinitialises itself over an empty state directory";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          StateDirectory = "testapp";
        };
        script = ''
          if [ ! -f ${statePath}/data ]; then
            echo FRESH-INIT > ${statePath}/data
          fi
          cat ${statePath}/data
        '';
      };

      environment.systemPackages = with pkgs; [
        cryptsetup
        clevis
        jose
        curl
        # To decrypt what `encrypted-state-header-backup --export` produces, which is the only way the export
        # subtest can assert anything stronger than "a file appeared".
        age
      ];

      # The non-interactive passphrase for encrypted-state-init. A real machine must never have this on a disk;
      # tmpfiles puts it on /run, which is a tmpfs, and the script itself prints a warning when this is used.
      systemd.tmpfiles.rules = [
        "f ${passphraseFile} 0600 root root - ${passphrase}"
        "f ${identityFile} 0600 root root - ${testAgeIdentity}"
      ];

      # Stands in for whatever the machine's repository uses to reach its owner. Starting a real notifier is not
      # this test's business; proving that something gets started, once, after the grace period, is.
      systemd.services.fake-notify = {
        description = "records that the outage notification fired";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.coreutils}/bin/touch /run/fake-notify-fired";
        };
      };

      systemd.services.fake-header-notify = {
        description = "records that the stale-header-backup notification fired";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.coreutils}/bin/touch /run/fake-header-notify-fired";
        };
      };

      # The healing retry timer is deliberately out of scope. Left on, a tick landing between two steps of this
      # script would start encrypted-state.target at a moment the test has arranged for it to be down, which is
      # precisely when it is checking that it is. The units are still built and still evaluated, and the subtests
      # that care about healing start the retry by hand; only the automatic trigger is removed.
      systemd.timers.encrypted-state-retry.wantedBy = lib.mkForce [ ];

      # Same reasoning for the header check: `Persistent = true` on a machine with no stamp fires at boot, and a
      # tick landing between two steps below would touch the flag the test is about to assert is absent. The unit
      # is still built and still evaluated, and the subtests start it by hand.
      systemd.timers.encrypted-state-header-check.wantedBy = lib.mkForce [ ];
    };
in
{
  name = "encrypted-state";

  nodes = {
    tang =
      { ... }:
      {
        imports = [ testNodes.base ];
        setup = {
          hostName = "tang";
          username = "giggio";
        };
        services.tang = {
          enable = true;
          listenStream = [ (toString tangPort) ];
          ipAddressAllow = [
            "192.168.1.0/24"
            "localhost"
          ];
        };
        networking.firewall.allowedTCPPorts = [ tangPort ];
      };

    client = mkNode {
      hostName = "client";
      # True from the first boot, which is not how a real migration goes - a real one switches with this false,
      # migrates, then switches again. Starting from `true` is what lets the subtests below observe the guard
      # working before the container exists at all, which is the state a key-server outage puts the machine into
      # and therefore the one worth asserting. `phase1` covers the sequence an operator actually types.
      bindState = true;
    };

    # The documented phase-1 machine: container enabled, nothing bound yet. It exists because both nodes here used
    # to start the unlock unit and the mount BY HAND before calling migrate, so the runbook - which says nothing
    # about either - was never the thing under test. It was wrong, and a rehearsal on a real VM found it rather
    # than this file: `encrypted-state-init` closed the container it had just made, and the next documented step
    # answered "the container is not mounted at /encrypted". Nothing in this node may type systemctl.
    phase1 = mkNode {
      hostName = "phase1";
      bindState = false;
    };
  };

  testScript = # python
    ''
      start_all()
      tang.wait_for_unit("tangd.socket")
      tang.wait_for_open_port(${toString tangPort})
      client.wait_for_unit("multi-user.target")

      # ---------------------------------------------------------------------------------------------------------
      # The documented phase-1 sequence, on `phase1`, typed exactly as docs/encrypted-state.md says to type it.
      # NOT ONE systemctl IN THIS SECTION - that is the point of it. Both nodes used to start the unlock unit and
      # the mount by hand before calling migrate, which meant the runbook itself was never under test; it was
      # missing a step, and a rehearsal on a real VM is what found that rather than this file.
      #
      # It runs first because a later subtest shuts the key server down for good.
      # ---------------------------------------------------------------------------------------------------------
      with subtest("phase 1: the machine boots with no container, and says why"):
          # multi-user.target must be reached even though the unlock cannot possibly succeed. A machine whose
          # container is missing has to come up far enough to be fixed over ssh.
          phase1.wait_for_unit("multi-user.target")
          phase1.wait_until_fails("systemctl is-active encrypted-state-unlock.service", timeout=60)
          journal = phase1.succeed("journalctl -u encrypted-state-unlock.service --no-pager")
          assert "encrypted-state-init" in journal, f"the failure does not say how to fix it: {journal}"
          # And a retry tick here is a no-op rather than a failure: between the first deploy and
          # encrypted-state-init there is no container to open, which is an operator action pending, not a fault.
          # A retry that failed here would put a red unit in front of someone who is midway through a runbook.
          # `retry_state`, not `retry`: the test driver puts its own `retry()` helper in this namespace and
          # typechecks the script, so shadowing it fails the build rather than the run.
          out = phase1.succeed("systemctl start encrypted-state-retry.service; echo started")
          phase1.log(out)
          retry_state = phase1.succeed(
              "systemctl show -p Result --value encrypted-state-retry.service"
          ).strip()
          assert retry_state == "success", f"a retry with no container should be a no-op, got: {retry_state}"
          phase1.fail("test -e /run/encrypted-state-outage-since")

      # State as it exists on a machine that has been running for years, before any of this landed.
      phase1.succeed("mkdir -p ${statePath}")
      phase1.succeed("echo PHASE1-DATA > ${statePath}/data")

      with subtest("phase 1: encrypted-state-init leaves the container MOUNTED"):
          # The defect this node exists for. init opens the container by hand to mkfs it and then closes it, so
          # returning there left nothing mounted - and the very next documented command answered "the container is
          # not mounted at /encrypted". It now hands over to systemd before returning.
          out = phase1.succeed("ENCRYPTED_STATE_PASSPHRASE_FILE=${passphraseFile} encrypted-state-init")
          phase1.log(out)
          phase1.succeed("findmnt -no TARGET ${mountPoint}")
          # Handed to systemd, not mounted behind its back: the unit that will do this at every future boot is the
          # unit that did it now, and its boot-time failure is cleared.
          phase1.require_unit_state("encrypted-state-unlock.service", "active")
          phase1.require_unit_state("${containerMountUnit}", "active")

      with subtest("phase 1: encrypted-state-migrate runs straight after init, with nothing in between"):
          out = phase1.succeed("encrypted-state-migrate")
          phase1.log(out)
          assert "PHASE1-DATA" in phase1.succeed("cat ${mountPoint}${statePath}/data")
          assert "PHASE1-DATA" in phase1.succeed("cat ${statePath}.premigrated/data")
          # bindState is still false, so the real path is now an empty mountpoint-to-be. That is the correct end
          # of phase 1: the data is in the container and the services stay down until the second deploy binds it.
          phase1.fail("test -f ${statePath}/data")

      with subtest("phase 1: nothing can start on the empty directory the migration left"):
          # The window between the migration and the second deploy, and the accident that happened in it on
          # gmktec1's first real migration: something pulled postgresql.service, it found an empty PGDATA where its
          # cluster used to be, and initdb built a new one on the root filesystem. bindState is still false here,
          # so RequiresMountsFor has no mount to hold anything back - masking is the only guard there is.
          # `succeed`, not `fail`: a unit whose condition is false is SKIPPED, and systemd calls that a successful
          # start. The property under test is not that starting errors - it is that starting writes nothing.
          phase1.succeed("systemctl start testapp.service")
          state = phase1.succeed("systemctl show -p ActiveState --value testapp.service").strip()
          assert state != "active", f"testapp ran on the empty directory the migration left: {state}"
          phase1.fail("test -f ${statePath}/data")
          # And the status command says so in its own words, rather than calling it "down" like an idle backup job.
          out = phase1.fail("encrypted-state-status")
          assert "held:" in out, f"status does not distinguish held-by-migration from down: {out}"

      with subtest("phase 1: a resumed migration is a no-op, not a failure"):
          # The first real migration was interrupted twice, so every later run met paths an earlier one had already
          # moved. Reporting those as failures ended a run in which everything was correctly migrated with "one or
          # more paths did not migrate" - the opposite of the truth, at the worst possible moment to read it.
          out = phase1.succeed("encrypted-state-migrate")
          phase1.log(out)
          assert "already migrated" in out, f"a resumed migration did not recognise its own work: {out}"

      with subtest("adding the container did not cost the machine its tmpfiles"):
          # Regression guard for a real defect. A mount unit under / is `Before=local-fs.target` by default, and
          # this one requires a service that needs the network - which every ordinary service reaches only after
          # sysinit.target, which is after systemd-tmpfiles-setup.service, which is after local-fs.target. systemd
          # resolves such a loop by DELETING one of the jobs and booting anyway; it chose tmpfiles-setup, so every
          # tmpfiles rule on the machine quietly did not run. Nothing else in this file noticed, because nothing
          # else looks at units the container has no business touching.
          boot_journal = client.succeed("journalctl -b --no-pager")
          assert "Found ordering cycle" not in boot_journal, (
              "the container's units created an ordering cycle; systemd deleted a job to break it. "
              "Look for 'deleted to break ordering cycle' in the journal to see which one."
          )
          client.require_unit_state("systemd-tmpfiles-setup.service", "active")

      with subtest("with no container, the service that owns the state does NOT start"):
          # This is the whole point of the file. RequiresMountsFor on a mount that cannot happen must keep the unit
          # down; if it ran, it would have written FRESH-INIT into what is really the mountpoint.
          client.fail("systemctl start testapp.service")
          client.fail("test -f ${statePath}/data")
          state = client.succeed("systemctl show -p ActiveState --value testapp.service").strip()
          client.log(f"testapp with no container: {state}")
          assert state != "active", f"testapp started without its state container: {state}"

      with subtest("encrypted-state-status reports the outage that systemctl hides"):
          # The reason this command exists: during a real outage `systemctl --failed` is usually empty and
          # `is-system-running` says `starting` forever, because encrypted-state-retry keeps restarting the unlock
          # and keeps a job queued. Found on the 2026-08-12 degrade rehearsal. So the EXIT STATUS is the contract -
          # it is what an alert watches - and a status command that exited 0 here would be worse than none.
          out = client.fail("encrypted-state-status")
          client.log(out)
          assert "DEGRADED" in out, f"status did not call this degraded: {out}"
          assert "${statePath}" in out, f"status did not name the path that is unserved: {out}"

      with subtest("the unlock unit fails loudly, naming the container"):
          client.fail("systemctl start encrypted-state-unlock.service")
          journal = client.succeed("journalctl -u encrypted-state-unlock.service --no-pager")
          assert "encrypted-state-init" in journal, f"the failure does not say how to fix it: {journal}"

      # Seed the state the way it exists on a machine that has been running for years, before any of this landed.
      client.succeed("mkdir -p ${statePath}")
      client.succeed("echo ORIGINAL-DATA > ${statePath}/data")

      with subtest("encrypted-state-init creates a container bound to the key server"):
          # Exits NON-ZERO here on purpose, and the failure is the assertion. This node has bindState=true over a
          # container that has never been migrated into, so init makes the container and then refuses to start
          # encrypted-state.target - which would bind its empty directories over the ORIGINAL-DATA seeded above,
          # and a service starting on that empty mountpoint is the accident the whole design exists to prevent.
          out = client.fail(
              "ENCRYPTED_STATE_PASSPHRASE_FILE=${passphraseFile} encrypted-state-init 2>&1"
          )
          client.log(out)
          assert "NOT starting encrypted-state.target" in out, (
              f"init did not refuse to bind an empty container over live data: {out}"
          )
          # It refused to hand over, not to build: the container is there and must not be made again.
          client.succeed("test -f ${image}")
          dump = client.succeed("cryptsetup luksDump ${image}")
          client.log(dump)
          assert "clevis" in dump, f"the container has no key-server binding: {dump}"
          # Two keyslots: the recovery passphrase and the pin-bound one. One would mean the bind silently did
          # nothing, and the machine would be one boot away from needing the passphrase typed by hand.
          slots = [line for line in dump.splitlines() if line.strip().endswith(": luks2")]
          assert len(slots) == 2, f"expected two keyslots, got {len(slots)}: {slots}"

      with subtest("the container is fully allocated, not sparse"):
          # A sparse container gives ENOSPC to writes from INSIDE it when the outer filesystem fills - so a database
          # fails at fsync because something unrelated filled the disk. `du` reports blocks actually allocated.
          apparent = int(client.succeed("stat -c %s ${image}").strip())
          allocated = int(client.succeed("du -B1 ${image} | cut -f1").strip())
          client.log(f"apparent {apparent}, allocated {allocated}")
          assert allocated >= apparent * 0.99, f"the container is sparse: {allocated} of {apparent} bytes allocated"

      with subtest("it refuses to format a container that already exists"):
          # The guard against the worst possible mistake: re-running init on a machine that already has data.
          client.fail("ENCRYPTED_STATE_PASSPHRASE_FILE=${passphraseFile} encrypted-state-init")
          client.succeed("test -f ${image}")

      with subtest("init leaves a header backup, and it is a real header"):
          # The one failure in this design that is total rather than granular. A damaged sector costs the file that
          # owns it and nothing else - aes-xts-plain64 takes its tweak from the sector number and chains nothing, so
          # damage cannot leave the sector it landed in - but the first 16 MiB are the keyslots, and the keyslots
          # hold the master key. Lose those and every byte behind them is unreadable. LUKS2 keeps a spare copy of
          # the BINARY header for exactly this, and cryptsetup falls back to it by itself, but the keyslot area is
          # not duplicated: the spare does not cover the case that matters.
          backup = "${headerBackup}"
          client.succeed(f"test -f {backup}")
          # The same header rather than merely 16 MiB of something: a header backup file is a LUKS device in its own
          # right, so cryptsetup will read it directly.
          assert client.succeed(f"cryptsetup luksUUID {backup}").strip() == client.succeed(
              "cryptsetup luksUUID ${image}"
          ).strip(), "the backup is not this container's header"
          # Taken AFTER the clevis bind, which is the ordering that decides whether a restored container can still
          # unlock by itself: the JWE lives in a LUKS2 token, inside the header, inside this file.
          assert "clevis" in client.succeed(f"cryptsetup luksDump {backup}"), (
              "the backup predates the key-server binding, so restoring it would leave only the passphrase"
          )
          client.succeed("encrypted-state-header-backup --check")
          assert "${headerBackup} current" in client.succeed("encrypted-state-status || true")
          # The timer is disabled on this node so it cannot fire mid-script, so assert instead that it is a real
          # unit with the schedule the module claims - otherwise "disabled for the test" could hide "never built".
          assert client.succeed(
              "systemctl show -p TimersCalendar --value encrypted-state-header-check.timer"
          ).strip() != "", "the daily header check timer is not configured"
          # Idempotent, because the alternative is rewriting 16 MiB on every run of anything that calls it.
          assert "unchanged" in client.succeed("encrypted-state-header-backup")

          # The copy that leaves the machine. Decrypted and compared, not merely produced: a mistyped recipient
          # yields a file that looks right, opens for nobody, and is discovered during a recovery.
          client.succeed("encrypted-state-header-backup --export /run/exported.age")
          client.succeed(
              "age --decrypt --identity ${identityFile} -o /run/exported.bak /run/exported.age"
          )
          client.succeed(f"cmp /run/exported.bak {backup}")
          # Refusing without a recipient matters more than it looks: the fallback would be writing the plaintext
          # header wherever it was pointed, which is the one thing this whole procedure exists to avoid.
          client.succeed("rm /run/exported.age /run/exported.bak")

      with subtest("a changed keyslot makes it stale, and restoring it is what makes it a backup"):
          # Negative control: if `--check` cannot tell a changed header from an unchanged one, "current" above was
          # never an assertion about anything.
          client.succeed("echo second-key > /run/second-key")
          client.succeed(
              "printf %s '${passphrase}' | cryptsetup luksAddKey --batch-mode --pbkdf argon2id"
              " --pbkdf-memory 32768 --key-file=- ${image} /run/second-key"
          )
          out = client.fail("encrypted-state-header-backup --check 2>&1")
          assert "STALE" in out, f"a third keyslot did not make the backup stale: {out}"
          assert "${headerBackup} STALE" in client.succeed("encrypted-state-status || true")

          # Reporting it to whoever runs a command is not enough, because the five commands that invalidate a
          # header backup are run once every few years and nobody goes looking afterwards. The daily check is what
          # turns "you should have remembered" into a message.
          client.fail("test -e /run/fake-header-notify-fired")
          client.succeed("systemctl start encrypted-state-header-check.service")
          client.wait_for_file("/run/fake-header-notify-fired")
          # Not a failed unit, deliberately: `--failed` and `degraded` mean "state is not coming from the container"
          # on these machines, and lending that alarm to paperwork is how an alarm stops being read.
          assert client.succeed(
              "systemctl show -p Result --value encrypted-state-header-check.service"
          ).strip() == "success"

          # And now the direction the whole thing exists for. "A file is present" is not the property under test;
          # putting it back and getting the original container is. Everything after this subtest unlocks through
          # clevis against the restored header, so the restore is load-bearing for the rest of the file.
          client.succeed(
              f"cryptsetup luksHeaderRestore --batch-mode ${image} --header-backup-file {backup}"
          )
          dump = client.succeed("cryptsetup luksDump ${image}")
          slots = [line for line in dump.splitlines() if line.strip().endswith(": luks2")]
          assert len(slots) == 2, f"the restore did not put the original two keyslots back: {slots}"
          assert "clevis" in dump, f"the restore lost the key-server binding: {dump}"
          client.succeed("encrypted-state-header-backup --check")

          # The nag has to stop when the problem is fixed, or it becomes the daily message everyone filters out.
          client.succeed("rm /run/fake-header-notify-fired")
          client.succeed("systemctl start encrypted-state-header-check.service")
          client.fail("test -e /run/fake-header-notify-fired")

      with subtest("encrypted-state-migrate moves the data in and parks the original"):
          client.succeed("systemctl start encrypted-state-unlock.service")
          client.succeed("systemctl start ${containerMountUnit}")
          out = client.succeed("encrypted-state-migrate")
          client.log(out)
          assert "ORIGINAL-DATA" in client.succeed("cat ${mountPoint}${statePath}/data")
          assert "ORIGINAL-DATA" in client.succeed("cat ${statePath}.premigrated/data")

      with subtest("the target brings up the bind mount and the service starts on the real data"):
          client.succeed("systemctl start encrypted-state.target")
          client.wait_for_unit("encrypted-state-unlock.service")
          mounts = client.succeed("findmnt -no SOURCE,TARGET ${statePath}")
          client.log(f"bind mount: {mounts}")
          assert "ORIGINAL-DATA" in client.succeed("cat ${statePath}/data")
          # The migration masked this unit; encrypted-state-resume is what lifts that, ordered after the bind
          # mounts so the mask ends exactly where the mount's own guard begins. Asserted before starting anything,
          # because a test that unmasks by hand would pass on a machine where nothing ever does.
          client.wait_for_unit("encrypted-state-resume.service")
          client.fail(
              "test -e /run/systemd/system/testapp.service.d/zz-encrypted-state-migration.conf"
          )
          client.succeed("systemctl start testapp.service")
          data = client.succeed("cat ${statePath}/data")
          assert "FRESH-INIT" not in data, "testapp reinitialised over real data"
          # And the other half of the status contract: zero once the container really is carrying the load. A
          # command that only ever reports trouble is one nobody trusts when it stays quiet.
          out = client.succeed("encrypted-state-status")
          client.log(out)
          assert "OK:" in out, f"status is not happy with a healthy container: {out}"

      with subtest("the performance flags asked for are the ones in the kernel"):
          # A flag that is silently dropped looks exactly like one that works, and the cost only shows up as latency
          # under a database months later.
          table = client.succeed("dmsetup table --target crypt encrypted-state")
          client.log(f"dm table: {table}")
          assert "no_read_workqueue" in table, f"read workqueue not bypassed: {table}"
          assert "no_write_workqueue" in table, f"write workqueue not bypassed: {table}"
          # And no allow_discards: discards would punch holes in the backing file and make it sparse again.
          assert "allow_discards" not in table, f"discards are enabled and will make the container sparse: {table}"

      with subtest("the loop device uses direct I/O"):
          dio = client.succeed(
              "losetup --associated ${image} --noheadings --output DIO"
          ).strip()
          assert dio == "1", f"the backing file is being cached twice: DIO={dio}"

      with subtest("it all comes back by itself after a reboot"):
          # shutdown()/start() rather than reboot(): the driver runs qemu with -no-reboot, so a guest that reboots
          # takes the process with it and every later step fails as "Shell disconnected". The disk persists across
          # this, which is the whole point - the container has to survive on it.
          client.shutdown()
          client.start()
          client.wait_for_unit("multi-user.target")
          client.wait_for_unit("encrypted-state-unlock.service")
          client.wait_until_succeeds("findmnt -no TARGET ${statePath}", timeout=60)
          assert "ORIGINAL-DATA" in client.succeed("cat ${statePath}/data")
          client.wait_for_unit("testapp.service")

      with subtest("encrypted-state-grow enlarges it online, without unmounting anything"):
          before = int(client.succeed("findmnt -bno SIZE ${mountPoint}").strip())
          client.succeed("encrypted-state-grow ${grownSize}")
          after = int(client.succeed("findmnt -bno SIZE ${mountPoint}").strip())
          client.log(f"container filesystem {before} -> {after}")
          assert after > before, f"the filesystem did not grow: {before} -> {after}"
          # Still mounted, still holding the data, and still bound out to the real path.
          assert "ORIGINAL-DATA" in client.succeed("cat ${statePath}/data")
          client.fail("encrypted-state-grow ${initialSize}")

      with subtest("with the key server gone, the service stays down and the data is not touched"):
          # The failure mode this whole design exists to make impossible. Everything above could work and this could
          # still be wrong, because it is the only subtest where the mount is absent while the machine is otherwise
          # healthy - which is what a dead key server looks like at 4am.
          tang.shutdown()
          client.shutdown()
          client.start()
          client.wait_for_unit("multi-user.target")
          client.wait_until_fails("systemctl is-active encrypted-state-unlock.service", timeout=120)
          client.fail("findmnt -no TARGET ${statePath}")

          # The machine has to LOOK dead, and until 2026-08-12 it did not: the unlock retried inside its own
          # ExecStart, so it was `activating` rather than `failed` for the whole outage. Nothing showed in
          # `systemctl --failed`, `is-system-running` stayed at `starting` because the retry kept a job queued,
          # OnFailure= never fired, and a `nixos-rebuild switch` blocked on the start job. Retrying moved to a
          # timer for exactly these four lines.
          failed = client.succeed("systemctl --failed --no-legend")
          client.log(f"systemctl --failed: {failed}")
          assert "encrypted-state-unlock" in failed, (
              f"a dead key server left nothing in systemctl --failed: {failed}"
          )
          running = client.succeed("systemctl is-system-running || true").strip()
          assert running == "degraded", f"the machine reports '{running}' with its state container down"

          with subtest("the outage is reported once, and only after the grace period"):
              # Started by hand because the timer is off in this test; what is under test is the script's decision,
              # not systemd's ability to run a timer.
              client.fail("test -e /run/fake-notify-fired")
              client.succeed("systemctl start encrypted-state-retry.service")
              client.succeed("test -e /run/encrypted-state-outage-since")
              client.wait_for_file("/run/fake-notify-fired")
              # Once. A notifier that fires on every tick is one that gets muted, and a muted alert is no alert.
              client.succeed("rm /run/fake-notify-fired")
              client.succeed("systemctl start encrypted-state-retry.service")
              client.fail("test -e /run/fake-notify-fired")

          state = client.succeed("systemctl show -p ActiveState --value testapp.service").strip()
          assert state != "active", f"testapp ran without its container: {state}"
          # The mountpoint must be empty - not carrying a new database written over the top of it.
          client.fail("test -f ${statePath}/data")
          # And the parked original is still there, which is what a rollback would use.
          assert "ORIGINAL-DATA" in client.succeed("cat ${statePath}.premigrated/data")

      with subtest("the recovery passphrase opens it with the key server gone"):
          # The other half of the promise: the pin is a convenience, the passphrase is the guarantee. If this does
          # not work, losing the key server loses the data.
          loop = client.succeed("losetup --find --show ${image}").strip()
          # `printf %s`, not `cat`: --key-file=- takes stdin literally, trailing newline and all, while the
          # interactive prompt a human would use strips it - and so does the `$(cat ...)` in init.sh. Feeding the
          # file straight through would hash one byte more than was enrolled and fail with "No key available",
          # which is the same message a genuinely wrong passphrase gives.
          client.succeed(
              f"printf %s '${passphrase}' | cryptsetup open --key-file=- {loop} recovered"
          )
          client.succeed("mkdir -p /mnt/recovered && mount /dev/mapper/recovered /mnt/recovered")
          assert "ORIGINAL-DATA" in client.succeed("cat /mnt/recovered${statePath}/data")
          client.succeed("umount /mnt/recovered && cryptsetup close recovered")
          client.succeed(f"losetup --detach {loop}")

      with subtest("when the key server comes back, the SERVICES come back too"):
          # The half of self-healing that opening the container does not buy, and which the move to a timer broke
          # without anything noticing. When the unlock fails at boot every guarded unit's job is CANCELLED with
          # result 'dependency' - not queued, cancelled - so a container that opens twenty minutes later brings up
          # the mounts and nothing else. RequiresMountsFor is a condition on starting, not a trigger to start.
          #
          # The old in-unit retry hid this by accident: while the unlock sat there `activating`, the dependent jobs
          # stayed queued, and a late success let them all proceed. Losing that is the price of failing fast, and
          # encrypted-state-retry starting the units itself is what pays it back.
          #
          # Found on a VM rehearsal where the container healed, `systemctl --failed` was empty, and
          # encrypted-state-status said OK - correctly, the paths really were served from the container - while all
          # thirty services sat there dead. Last, because it is the only subtest that ends with a healthy machine.
          tang.start()
          tang.wait_for_unit("tangd.socket")
          tang.wait_for_open_port(${toString tangPort})
          client.succeed("systemctl start encrypted-state-retry.service")
          client.wait_for_unit("encrypted-state-unlock.service")
          source = client.succeed("findmnt -no SOURCE --target ${statePath}").strip()
          assert "encrypted-state" in source, f"the retry did not bring the container back: {source}"
          client.wait_for_unit("testapp.service")
          # On the real data, not on a fresh directory created over the top of a bind mount that never happened.
          assert "ORIGINAL-DATA" in client.succeed("cat ${statePath}/data")
    '';
}
