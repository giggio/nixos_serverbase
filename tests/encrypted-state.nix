{
  pkgs,
  testNodes,
  ...
}:

# Covers modules/serverbase/services/encrypted-state - the clevis-unlocked LUKS container that application state is
# bind-mounted out of, and the init/migrate/grow scripts that manage it.
#
# The subtest that justifies the whole file is "a locked container keeps the service DOWN". Everything else here is
# ordinary plumbing that would be caught the first time someone looked; that one is not. If the container fails to
# unlock, /var/lib/<service> is an empty directory on the root filesystem, and a database finding an empty data
# directory does not report an error - it initialises a brand new empty database over the top of the mountpoint and
# reports success. The real service would then be serving nothing, having overwritten nothing, and the only signal
# would be a user saying their passwords are gone. So `testapp` below is written to behave exactly that badly on
# purpose, and the test asserts it never gets the chance.
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

    client =
      { nodes, lib, ... }:
      {
        imports = [ testNodes.base ];
        setup = {
          hostName = "client";
          username = "giggio";
          encryptedState = {
            enable = true;
            # True from the first boot, which is not how a real migration goes - a real one switches with this false,
            # migrates, then switches again. Starting from `true` is what lets the first subtest observe the guard
            # working before the container exists at all, which is the state a key-server outage puts the machine
            # into and therefore the one worth asserting.
            bindState = true;
            inherit image mountPoint;
            size = initialSize;
            # 32 MiB rather than the 256 MiB default. argon2id allocates this for real, twice per test run, on a node
            # with 1 GiB - and what is being tested is the plumbing around the KDF, not the KDF.
            pbkdfMemoryKiB = 32768;
            clevisConfig = builtins.toJSON {
              url = "http://${nodes.tang.networking.primaryIPAddress}:${toString tangPort}";
            };
            # Short, so the negative case fails inside the test's patience rather than at the driver's timeout.
            unlockAttempts = 2;
            unlockDelaySeconds = 2;
            paths."${statePath}" = [ "testapp.service" ];
          };
        };

        # Room for the container plus the grown container plus the pre-migration copy.
        virtualisation.diskSize = 4096;

        # Stands in for a database server, and specifically for the thing that makes one dangerous: finding no data,
        # it creates some and calls that success. If this ever writes FRESH-INIT after the first subtest, the guard
        # has failed and a real database would have been silently replaced.
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
        ];

        # The non-interactive passphrase for encrypted-state-init. A real machine must never have this on a disk;
        # tmpfiles puts it on /run, which is a tmpfs, and the script itself prints a warning when this is used.
        systemd.tmpfiles.rules = [
          "f ${passphraseFile} 0600 root root - ${passphrase}"
        ];

        # The healing retry loop is deliberately out of scope. Left on, an OnFailure firing between two steps of this
        # script would start encrypted-state.target - and therefore the bind mounts - at a moment the test has
        # arranged for them to be down, which is precisely when it is checking that they are. The unit itself is
        # still built and still evaluated; only the trigger is removed.
        systemd.services.encrypted-state-unlock.onFailure = lib.mkForce [ ];
      };
  };

  testScript = # python
    ''
      start_all()
      tang.wait_for_unit("tangd.socket")
      tang.wait_for_open_port(${toString tangPort})
      client.wait_for_unit("multi-user.target")

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

      with subtest("the unlock unit fails loudly, naming the container"):
          client.fail("systemctl start encrypted-state-unlock.service")
          journal = client.succeed("journalctl -u encrypted-state-unlock.service --no-pager")
          assert "encrypted-state-init" in journal, f"the failure does not say how to fix it: {journal}"

      # Seed the state the way it exists on a machine that has been running for years, before any of this landed.
      client.succeed("mkdir -p ${statePath}")
      client.succeed("echo ORIGINAL-DATA > ${statePath}/data")

      with subtest("encrypted-state-init creates a container bound to the key server"):
          client.succeed(
              "ENCRYPTED_STATE_PASSPHRASE_FILE=${passphraseFile} encrypted-state-init"
          )
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
          client.succeed("systemctl start testapp.service")
          data = client.succeed("cat ${statePath}/data")
          assert "FRESH-INIT" not in data, "testapp reinitialised over real data"

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
    '';
}
