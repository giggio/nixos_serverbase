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

    with subtest("the boot journal has no ordering cycle"):
        # Same assertion as the other encrypted-state check, for the same reason: systemd answers a cycle by
        # deleting a job and booting anyway, and integrity adds another device layer under the mount.
        client.fail("journalctl -b | grep -q 'ordering cycle'")
  '';
}
