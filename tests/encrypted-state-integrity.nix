{
  pkgs,
  testNodes,
  ...
}:

# Covers `setup.encryptedState.integrity` - dm-integrity stacked under dm-crypt, so a corrupt sector returns EIO at
# its own offset instead of plausible garbage.
#
# Separate from tests/encrypted-state.nix rather than another subtest in it, for two reasons. Formatting with
# integrity wipes the whole container before luksFormat returns, which changes the timing of everything downstream;
# and this is the feature that will be decided on for a machine holding 1.4 TB, so it deserves a check that can be
# run and read on its own.
#
# THE SUBTEST THAT JUSTIFIES THE FILE is "a corrupted sector is refused, not returned", together with the plain-LUKS
# control immediately after it. Everything else here could pass with integrity silently doing nothing: the container
# would format, bind, unlock, mount and serve exactly the same. Only reading damaged bytes back tells the two apart,
# which is why the control matters as much as the assertion - it shows the same damage IS returned without it.

let
  tangPort = 7500;
  image = "/var/lib/encrypted-state.img";
  mountPoint = "/encrypted";
  statePath = "/var/lib/testapp";
  passphraseFile = "/run/test-recovery-passphrase";
  passphrase = "test-recovery-passphrase-not-a-real-one";
  containerSize = "256M";
  grownSize = "384M";

  # The hand-built pair. Deliberately NOT built through the module: they hold no filesystem, just a known byte
  # pattern written straight to the mapper, so a failed read cannot be blamed on ext4 noticing something. Same size,
  # same sector size, same corruption at the same offset - the only difference is --integrity.
  probeMiB = 128;
  # Past the 16 MiB LUKS header and past dm-integrity's superblock and journal, which sit at the front of what is
  # left, so this lands in the interleaved tag-and-data region on one and in plain data on the other. Half way in,
  # so it stays true if the journal grows.
  corruptAt = probeMiB / 2 * 1024 * 1024;
  corruptLen = 1024 * 1024;
in
{
  name = "encrypted-state-integrity";

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
            inherit image mountPoint;
            size = containerSize;
            bindState = false;
            integrity = "hmac-sha256";
            sectorSize = 4096;
            pbkdfMemoryKiB = 32768;
            clevisConfig = builtins.toJSON {
              url = "http://${nodes.tang.networking.primaryIPAddress}:${toString tangPort}";
            };
            unlockAttemptTimeoutSeconds = 20;
            paths."${statePath}" = [ "testapp.service" ];
          };
        };

        virtualisation.diskSize = 4096;

        systemd.services.testapp = {
          description = "a service that owns the state directory";
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

        systemd.tmpfiles.rules = [
          "f ${passphraseFile} 0600 root root - ${passphrase}"
        ];

        systemd.timers.encrypted-state-retry.wantedBy = lib.mkForce [ ];
        systemd.timers.encrypted-state-header-check.wantedBy = lib.mkForce [ ];
      };
  };

  testScript = ''
    import re

    start_all()
    tang.wait_for_unit("tangd.socket")
    tang.wait_for_open_port(${toString tangPort})
    client.wait_for_unit("multi-user.target")

    with subtest("the kernel can actually do this"):
        # A missing DM_INTEGRITY does not produce a helpful message from cryptsetup - it produces "Kernel does not
        # support dm-integrity mapping" from inside encrypted-state-init, several steps into a runbook. Asked here
        # so a kernel that cannot do this reads as a kernel that cannot do this. It is also the assertion that will
        # fire on opi4pronas if the symbols are ever dropped from the vendor config by `make oldconfig`.
        # `dmsetup targets` lists what is LOADED, not what the kernel can do - dm-integrity is autoloaded by
        # cryptsetup at format time, so asking before that lists neither. modprobe first, which also succeeds for a
        # target built in rather than modular, as it is on opi4pronas's monolithic vendor kernel.
        client.succeed("modprobe dm-integrity")
        targets = client.succeed("dmsetup targets")
        client.log(targets)
        assert "integrity" in targets, f"the kernel has no dm-integrity target: {targets}"

    with subtest("encrypted-state-init formats with integrity and clevis can still open it"):
        # The whole-device wipe happens inside this call, so it is slower than the plain case by design.
        out = client.succeed(
            "ENCRYPTED_STATE_PASSPHRASE_FILE=${passphraseFile} encrypted-state-init", timeout=900
        )
        client.log(out)

        dump = client.succeed("cryptsetup luksDump ${image}")
        client.log(dump)
        # The three things that cannot be changed after this moment, all read back off the header rather than
        # assumed from the options that asked for them.
        assert "integrity: hmac(sha256)" in dump, f"the container was formatted without integrity: {dump}"
        assert "sector: 4096 [bytes]" in dump, f"sector size was not pinned: {dump}"
        assert "clevis" in dump, f"integrity broke the key-server binding: {dump}"

        # And it is genuinely open and serving, not merely formatted: init finishes by starting the target, which
        # is the same path every later boot takes.
        client.succeed("mountpoint -q ${mountPoint}")

        # What the kernel actually built, rather than what cryptsetup was asked for. An authenticated LUKS2 volume
        # is TWO device-mapper devices - an integrity target with the crypt target stacked on it - and a header
        # that says `integrity:` while the kernel runs a bare crypt target would be the worst possible outcome:
        # every assertion above passes and nothing is checked at runtime.
        table = client.succeed("dmsetup table")
        client.log(table)
        assert " integrity " in table, f"no dm-integrity target in the stack: {table}"
        assert " crypt " in table, f"no dm-crypt target in the stack: {table}"

        # The performance flags the module asks for on every unlock. They are passed through clevis to
        # `cryptsetup open`, and stacking integrity underneath is exactly the sort of change that could silently
        # drop them - the container would still work, a little slower, with nothing to show for it.
        assert "no_read_workqueue" in table and "no_write_workqueue" in table, (
            f"the dm-crypt performance flags did not survive integrity: {table}"
        )

    with subtest("what the tags and the journal actually cost"):
        # The number step 6 needs and could not be measured on the workstation, because dm-integrity is not in its
        # kernel. Logged rather than pinned to a constant: the point is to know it, and a tight assertion here
        # would fail on any cryptsetup that changes its default journal size.
        image_bytes = int(client.succeed("stat -c %s ${image}").strip())
        usable = int(client.succeed("blockdev --getsize64 /dev/mapper/encrypted-state").strip())
        overhead = (image_bytes - usable) / image_bytes
        client.log(
            f"image {image_bytes} bytes, usable {usable} bytes, overhead {overhead * 100:.2f}%"
        )
        # 16 MiB of LUKS header on a 256 MiB container is 6.25% on its own, so the band is wide at this scale and
        # would be far tighter on a real one. It is here to catch a change of ORDER - tags landing at 512-byte
        # granularity, or a journal sized as a fraction of the device.
        assert 0.05 < overhead < 0.35, f"overhead {overhead:.3f} is not in the expected range"

    with subtest("what it costs at a realistic size"):
        # The container this is being decided for is 1.6 T, and overhead measured on 128 and 256 MiB might be a
        # fixed minimum rather than a proportion. --integrity-no-wipe makes the question cheap: the tags are left
        # uninitialised, so nothing is written and nothing can be read, but cryptsetup still does the arithmetic
        # and the mapped size is the answer. Sparse, so 64 GiB costs nothing on a 4 GiB disk.
        client.succeed("truncate -s 64G /root/big.img")
        client.succeed(
            "printf %s '${passphrase}' | cryptsetup luksFormat --type luks2 --batch-mode"
            " --pbkdf argon2id --pbkdf-memory 32768 --sector-size 4096"
            " --integrity hmac-sha256 --integrity-no-wipe --key-file - /root/big.img",
            timeout=600,
        )
        client.succeed(
            "printf %s '${passphrase}' | cryptsetup open --key-file - /root/big.img big"
        )
        big_usable = int(client.succeed("blockdev --getsize64 /dev/mapper/big").strip())
        client.succeed("cryptsetup close big && rm -f /root/big.img")
        # Measured against the area AFTER the 16 MiB LUKS header, because that part is a flat cost that does not
        # scale and would swamp the ratio at small sizes.
        area = 64 * 1024 ** 3 - 16 * 1024 ** 2
        client.log(
            f"64 GiB: {big_usable} usable of {area} after the header,"
            f" integrity overhead {(area - big_usable) / area * 100:.2f}%"
        )

    with subtest("data written through it survives a close and reopen"):
        client.succeed("encrypted-state-migrate")
        client.succeed("dd if=/dev/urandom of=${mountPoint}/probe bs=1M count=32 status=none")
        before = client.succeed("md5sum ${mountPoint}/probe").split()[0]
        client.succeed("sync")
        client.succeed("systemctl stop encrypted-state.target")
        client.succeed("systemctl start encrypted-state.target")
        client.wait_until_succeeds("mountpoint -q ${mountPoint}", timeout=60)
        after = client.succeed("md5sum ${mountPoint}/probe").split()[0]
        assert before == after, "the file changed across a close and reopen"

    with subtest("encrypted-state-grow refuses, because cryptsetup cannot resize this"):
        # Found by this test rather than by reasoning, and it costs the plan an assumption: growing an integrity
        # container is NOT possible. cryptsetup answers "Resize of LUKS2 device with integrity protection is not
        # supported", and there is no offline route either - the tag area is interleaved with the data, so
        # extending one means rewriting the other.
        #
        # What matters here is that it refuses BEFORE touching anything. The first version did not: fallocate and
        # `losetup --set-capacity` both succeeded and cryptsetup failed after them, leaving the image and the loop
        # device larger than the LUKS device, with the difference unusable forever.
        before_bytes = int(client.succeed("stat -c %s ${image}").strip())
        out = client.fail("encrypted-state-grow ${grownSize} 2>&1")
        client.log(out)
        assert "cannot resize" in out, f"grow failed for some other reason: {out}"
        assert "migrate into it" in out, "the refusal does not say what to do instead"
        assert int(client.succeed("stat -c %s ${image}").strip()) == before_bytes, (
            "grow enlarged the image before refusing, which is the failure this guard exists to prevent"
        )
        assert client.succeed("md5sum ${mountPoint}/probe").split()[0] == before, (
            "the refused grow changed the data in the container"
        )

    with subtest("a corrupted sector is refused, not returned"):
        # THE POINT OF THE FILE. A byte is written into the raw container behind dm-crypt's back, which is exactly
        # what a bad sector, a misdirected write or a flipped bit in non-ECC RAM looks like from above.
        #
        # No filesystem is involved: the probe device holds a pattern written straight to the mapper, so a refused
        # read cannot be ext4 noticing its own metadata is wrong. Built by hand rather than through the module
        # because the module gives a machine one container, and this needs a matched pair.
        client.succeed("dd if=/dev/zero of=/root/intg.img bs=1M count=${toString probeMiB} status=none")
        client.succeed(
            "printf %s '${passphrase}' | cryptsetup luksFormat --type luks2 --batch-mode"
            " --pbkdf argon2id --pbkdf-memory 32768 --sector-size 4096"
            " --integrity hmac-sha256 --key-file - /root/intg.img",
            timeout=900,
        )
        client.succeed(
            "printf %s '${passphrase}' | cryptsetup open --key-file - /root/intg.img intg"
        )
        size = int(client.succeed("blockdev --getsize64 /dev/mapper/intg").strip())
        client.log(f"integrity probe device: {size} bytes usable of ${toString (probeMiB * 1024 * 1024)}")
        client.succeed(f"dd if=/dev/zero of=/dev/mapper/intg bs=1M count={size // (1024 * 1024)} status=none")
        client.succeed("sync && cryptsetup close intg")

        client.succeed(
            "dd if=/dev/urandom of=/root/intg.img bs=1 seek=${toString corruptAt}"
            " count=${toString corruptLen} conv=notrunc status=none"
        )

        client.succeed(
            "printf %s '${passphrase}' | cryptsetup open --key-file - /root/intg.img intg"
        )
        # Reading the whole device must fail. `dd` returns non-zero on the I/O error rather than quietly returning
        # short, which is the behaviour the backup job downstream depends on.
        client.fail("dd if=/dev/mapper/intg of=/dev/null bs=1M status=none")
        # `log` is the driver's own logger; shadowing it breaks the type check.
        kmsg = client.succeed("dmesg | tail -40")
        client.log(kmsg)
        assert "integrity" in kmsg.lower(), f"nothing in the kernel log names integrity: {kmsg}"
        client.succeed("cryptsetup close intg")

    with subtest("without integrity the same damage is returned as if it were data"):
        # The control, and the reason the assertion above is not vacuous. Identical size, sector size, passphrase,
        # pattern and corruption - only --integrity is missing. If this ALSO failed, the subtest above would be
        # proving something about dd or about loop devices rather than about integrity.
        client.succeed("dd if=/dev/zero of=/root/plain.img bs=1M count=${toString probeMiB} status=none")
        client.succeed(
            "printf %s '${passphrase}' | cryptsetup luksFormat --type luks2 --batch-mode"
            " --pbkdf argon2id --pbkdf-memory 32768 --sector-size 4096"
            " --key-file - /root/plain.img"
        )
        client.succeed(
            "printf %s '${passphrase}' | cryptsetup open --key-file - /root/plain.img plain"
        )
        size = int(client.succeed("blockdev --getsize64 /dev/mapper/plain").strip())
        client.succeed(f"dd if=/dev/zero of=/dev/mapper/plain bs=1M count={size // (1024 * 1024)} status=none")
        client.succeed("sync")
        clean = client.succeed("md5sum /dev/mapper/plain").split()[0]
        client.succeed("cryptsetup close plain")

        client.succeed(
            "dd if=/dev/urandom of=/root/plain.img bs=1 seek=${toString corruptAt}"
            " count=${toString corruptLen} conv=notrunc status=none"
        )
        client.succeed(
            "printf %s '${passphrase}' | cryptsetup open --key-file - /root/plain.img plain"
        )
        # Succeeds, and hands up bytes that are not the ones that were written. That is the status quo on every
        # unencrypted and every plain-LUKS volume here, and it is what gets copied into a backup.
        dirty = client.succeed("md5sum /dev/mapper/plain").split()[0]
        assert dirty != clean, (
            "the corruption did not reach the plain device, so the integrity subtest proved nothing"
        )
        client.succeed("cryptsetup close plain")

    with subtest("an interrupted init leaves a container that can be resumed, not one that must be redone"):
        # THE REGRESSION THIS EXISTS FOR. cryptsetup's own `--integrity` wipe keeps no record of how far it got, so
        # any interruption costs the whole thing - which on opi4pronas's 4 TiB container is two days, lost twice:
        # to this module's retry timer on 2026-08-20 and to a power cut on 2026-08-22, the second time at 98.6%.
        # The module now formats with --integrity-no-wipe and does the wiping itself, in chunks, recording the
        # offset. Everything below is that record being trusted, and the guards that keep it trustworthy.
        client.succeed("systemctl stop encrypted-state.target || true")
        client.succeed("umount ${mountPoint} || true")
        client.succeed("cryptsetup close encrypted-state || true")
        client.succeed("losetup -D || true")
        client.succeed("rm -f ${image} /var/lib/encrypted-state-wipe")

        # systemd-run rather than a shell job, because that is how a run this long is actually started on a real
        # machine - and because it gives something to send a signal to.
        client.succeed(
            "systemd-run --unit=init-under-test"
            " --setenv=ENCRYPTED_STATE_PASSPHRASE_FILE=${passphraseFile}"
            " encrypted-state-init"
        )
        # Kill it the moment the wipe has recorded any progress at all. A SIGKILL, not a SIGTERM: the point is to
        # prove the design survives a process that got no chance to tidy up, which is what a power cut is.
        client.wait_until_succeeds("test -e /var/lib/encrypted-state-wipe", timeout=300)
        client.succeed("systemctl kill --signal=KILL init-under-test || true")
        client.wait_until_fails("systemctl is-active --quiet init-under-test", timeout=60)
        # And wait for the LOCK, not just for the unit. `systemctl kill` returns before the cgroup is reaped, so a
        # lingering child can still hold the flock for a moment after the unit reports inactive - and the unlock
        # checks the lock before it checks anything else, so whatever runs next would be refused for the wrong
        # reason. Taking the lock non-blockingly is the only honest way to ask whether it is free.
        client.wait_until_succeeds("flock -n /run/encrypted-state.lock true", timeout=60)

        # What has to be true of the wreckage: the container exists, it is bound to the key server, and the
        # binding happened BEFORE the long part rather than after it. That ordering is the whole reason a power
        # cut is now survivable - the 2026-08-22 container had no clevis token at all, because `clevis luks bind`
        # ran after a `luksFormat` that never returned.
        client.succeed("test -e ${image}")
        dump = client.succeed("cryptsetup luksDump ${image}")
        assert "clevis" in dump, f"the binding is not made before the wipe, so an interruption is still fatal: {dump}"
        client.log(client.succeed("cat /var/lib/encrypted-state-wipe"))

    with subtest("a container whose wipe is unfinished refuses to open"):
        # Reading past the wipe frontier is an integrity failure by construction, so an ext4 laid over one works
        # perfectly until the allocator reaches the uninitialised region and then returns EIO from somewhere
        # unrelated. The unlock has to refuse rather than let that happen, and refusing is only meaningful if it
        # also fails the unit - a warning would be read past.
        # Rewind the recorded offset to almost nothing. wipe_size is left exactly as the wipe wrote it - it is the
        # size of the MAPPED device, which is not the size of the image file and cannot be asked of the file.
        # 128 MiB, deliberately more than the 64 MiB chunk the wipe backs off by, so that the resume below starts
        # from a NON-ZERO offset. Rewinding to almost-zero would let a wipe that quietly restarts from the
        # beginning pass the assertion that it resumed.
        client.succeed(
            "sed -i 's/^wipe_offset=.*/wipe_offset=134217728/' /var/lib/encrypted-state-wipe"
        )
        # Driven as the UNIT rather than as a command, and not only because the script is not on $PATH - it is the
        # unit that has to fail. A script that printed a warning and returned zero would let the mount unit, which
        # Requires= this one, go ahead and mount the half-initialised container.
        # Stopped first, and this is a trap worth naming: the unlock unit is oneshot with RemainAfterExit, so if it
        # is already active - which it may well be, since the kill above can land after the wipe finished - then
        # `systemctl start` is a silent no-op that succeeds and proves nothing.
        client.succeed("systemctl stop encrypted-state.target || true")
        client.succeed("systemctl stop encrypted-state-unlock.service || true")
        client.succeed("systemctl reset-failed encrypted-state-unlock.service || true")
        client.fail("systemctl start encrypted-state-unlock.service")
        # Waited for rather than read once. `systemctl start` returns when the job is done, but the script's
        # stdout reaches the journal through a separate path and is not necessarily committed yet - reading
        # immediately gets systemd's own "Starting..." line and none of the script's.
        client.wait_until_succeeds(
            "journalctl -u encrypted-state-unlock.service --no-pager -n 100 | grep -q 'is not finished'",
            timeout=30,
        )
        out = client.succeed("journalctl -u encrypted-state-unlock.service --no-pager -n 100")
        client.log(out)
        assert "not finished" in out, f"the unlock opened a container with an unfinished wipe: {out}"
        client.fail("test -e /dev/mapper/encrypted-state")

    with subtest("a progress record from a different container is refused, not followed"):
        # The one failure this design can produce that the all-or-nothing version could not. A stale record left by
        # a container that was deleted and recreated would make the wipe skip however far the OLD one got, leaving
        # a region of the NEW one with uninitialised tags that nothing will ever check again. Silent, permanent,
        # and only discovered years later by a read that fails. It has to be a hard refusal.
        client.succeed(
            "sed -i 's/^wipe_uuid=.*/wipe_uuid=00000000-0000-0000-0000-000000000000/'"
            " /var/lib/encrypted-state-wipe"
        )
        out = client.fail("encrypted-state-wipe 2>&1")
        client.log(out)
        assert "DIFFERENT container" in out, f"a stale progress record was followed: {out}"
        out = client.fail("encrypted-state-init --resume 2>&1")
        assert "stale record" in out.lower(), f"--resume followed a stale progress record: {out}"

        # And --resume must refuse outright when there is no record, because the next thing it does is mkfs.
        client.succeed("mv /var/lib/encrypted-state-wipe /root/wipe.saved")
        out = client.fail("encrypted-state-init --resume 2>&1")
        assert "no record" in out, f"--resume ran without a record of an unfinished init: {out}"
        client.succeed("mv /root/wipe.saved /var/lib/encrypted-state-wipe")

        # Undo the poisoned UUID here, in the subtest that set it, so what follows starts from a clean record.
        real_uuid = client.succeed("cryptsetup luksUUID ${image}").strip()
        client.succeed(
            f"sed -i 's/^wipe_uuid=.*/wipe_uuid={real_uuid}/' /var/lib/encrypted-state-wipe"
        )

    with subtest("a container left open with an unfinished wipe is closed, not refused"):
        # The exact sequence that failed on opi4pronas on 2026-08-23, reproduced rather than described. Salvaging
        # a container means binding it by hand first, and between that and writing the progress record there is a
        # window in which the retry timer and `nixos-rebuild switch` both legitimately open it - the guard has no
        # record to read yet. The wipe then found a loop device that already carried a mapping and gave up with
        # "Cannot use device /dev/loop0 which is in use".
        # Test setup, not part of what is being proven: the SIGKILLed wipe earlier left `encrypted-state-wiping`
        # mapped onto the loop device, and the unlock would trip over that instead of the condition under test.
        client.succeed("cryptsetup close encrypted-state-wiping || true")
        client.succeed("losetup -D || true")
        client.succeed("mv /var/lib/encrypted-state-wipe /root/wipe.hidden")
        client.succeed("systemctl reset-failed encrypted-state-unlock.service || true")
        client.succeed("systemctl start encrypted-state-unlock.service")
        client.succeed("test -e /dev/mapper/encrypted-state")
        client.succeed("mv /root/wipe.hidden /var/lib/encrypted-state-wipe")

        rc, out = client.execute("encrypted-state-wipe 2>&1", timeout=900)
        client.log(out)
        assert rc == 0, f"the wipe could not deal with an open container: {out}"
        assert "closing it before wiping" in out, f"the wipe did not take down the open container: {out}"
        assert "in use" not in out, f"the wipe still tripped over the existing mapping: {out}"

        # And systemd's view has to match the world afterwards: the unlock unit is oneshot with RemainAfterExit,
        # so closing the device behind its back would leave it reporting active over nothing.
        state = client.succeed("systemctl is-active encrypted-state-unlock.service || true").strip()
        assert state != "active", f"the unlock unit still claims to be active: {state}"

        # Put it back to unfinished for the resume subtest below.
        client.succeed(
            "sed -i 's/^wipe_offset=.*/wipe_offset=134217728/' /var/lib/encrypted-state-wipe"
        )

    with subtest("the wipe resumes where it stopped, and --resume finishes the container"):
        # Resuming rather than restarting is the entire feature, so it is asserted on the log rather than inferred
        # from the container working afterwards - a wipe that silently started again from zero would also produce
        # a working container, just two days later.
        # Driven through systemd rather than run from the test's shell, and that is not incidental.
        # writeShellApplication PREPENDS its runtimeInputs to the inherited PATH, so a script run from a login
        # shell quietly finds tools that were never declared - and the same script run from a unit, where PATH is
        # minimal, does not. A missing `gawk` passed every check here and failed on the real machine.
        client.succeed("systemd-run --unit=resume-wipe encrypted-state-wipe")
        client.wait_until_fails("systemctl is-active --quiet resume-wipe", timeout=900)
        result = client.succeed("systemctl show resume-wipe -p Result --value").strip()
        client.wait_until_succeeds(
            "journalctl -u resume-wipe --no-pager | grep -q 'is complete'", timeout=30
        )
        out = client.succeed("journalctl -u resume-wipe --no-pager")
        client.log(out)
        assert result == "success", f"the wipe failed under systemd: {result}\n{out}"
        assert "command not found" not in out, f"a runtime input is missing from the script: {out}"
        assert "Resuming" in out, f"the wipe restarted from the beginning instead of resuming: {out}"
        assert "at 0 " not in out, f"the wipe said it resumed but started from zero anyway: {out}"
        # The percentage renders as a number, which is what proves awk actually ran rather than failing quietly
        # into an empty string - the real symptom was a progress line reading "(% done)".
        assert re.search(r"\(\d+\.\d+% done\)", out), f"the progress percentage did not render: {out}"

        record = client.succeed("cat /var/lib/encrypted-state-wipe")
        offset = int([l for l in record.splitlines() if l.startswith("wipe_offset=")][0].split("=")[1])
        total = int([l for l in record.splitlines() if l.startswith("wipe_size=")][0].split("=")[1])
        assert offset == total, f"the wipe reported success without reaching the end: {record}"

        # And the container can now be finished without redoing any of it.
        out = client.succeed("encrypted-state-init --resume", timeout=900)
        client.log(out)
        client.succeed("mountpoint -q ${mountPoint}")
        # The marker is what --resume keys off, so leaving it behind would let a later --resume mkfs over a
        # container in service. It has to be gone the moment the init is genuinely finished.
        client.fail("test -e /var/lib/encrypted-state-wipe")

    with subtest("close declines to tear down a container an operation owns"):
        # encrypted-state-close is the ExecStop of the unlock unit, so it runs on every stop and every shutdown -
        # and it detaches the loop device backing the image regardless of what is stacked on it. During a wipe
        # that is the device the wipe writes through. It cannot take the lock, because a stop job that fails
        # because something else holds a lock is worse than what it prevents, so it tests it instead.
        client.succeed("mountpoint -q ${mountPoint}")
        # Absolute paths on both halves. A transient unit gets systemd's compiled-in default PATH, which on NixOS
        # points at /usr/bin and friends that do not exist - so `flock` would start and then fail to exec `sleep`.
        # The same trap as the missing gawk, from the other direction.
        client.succeed(
            "systemd-run --unit=lock-holder /run/current-system/sw/bin/flock"
            " /run/encrypted-state.lock /run/current-system/sw/bin/sleep 120"
        )
        client.wait_until_succeeds("systemctl is-active --quiet lock-holder", timeout=30)
        client.wait_until_fails("flock -n /run/encrypted-state.lock true", timeout=30)

        rc, out = client.execute("encrypted-state-close 2>&1")
        client.log(out)
        # Exit zero regardless: this runs at shutdown, where a non-zero exit marks the unit failed on an
        # otherwise clean stop.
        assert rc == 0, f"close returned {rc} while an operation held the lock: {out}"
        assert "owns the container" in out, f"close did not decline: {out}"

        # The two things that had to survive, checked against the world rather than against the message.
        client.succeed("losetup -a | grep -q ${image}")
        client.succeed("mountpoint -q ${mountPoint}")

        # And once the lock is free it does its job as before, or this would be a guard that never opens.
        client.succeed("systemctl stop lock-holder")
        client.wait_until_succeeds("flock -n /run/encrypted-state.lock true", timeout=30)
        client.succeed("umount ${mountPoint}")
        out = client.succeed("encrypted-state-close 2>&1")
        client.log(out)
        assert "closed /dev/mapper/encrypted-state" in out, f"close did not run with the lock free: {out}"
        client.fail("losetup -a | grep -q ${image}")

    with subtest("the boot journal has no ordering cycle"):
        # Same assertion as the other encrypted-state check, for the same reason: systemd answers a cycle by
        # deleting a job and booting anyway, and integrity adds another device layer under the mount.
        client.fail("journalctl -b | grep -q 'ordering cycle'")
  '';
}
