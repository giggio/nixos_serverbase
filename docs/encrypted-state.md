# Encrypted application state

`setup.encryptedState`: a LUKS2 container, held in a file on the ordinary root filesystem, whose key comes from a
clevis pin rather than from anything stored on the machine. Application state is bind-mounted out of it onto the
paths the services already use, so nothing downstream changes — a service still writes to `/var/lib/<its own name>`
and never learns that the directory is somewhere else.

Implemented in `modules/serverbase/services/encrypted-state/`.

This file describes the mechanism. **Which paths a machine puts in it, and which key server it asks, belong to the
repository that owns the machine** — this one knows nothing about either. A superproject using this module should
have its own `docs/encrypted-state.md` covering the site-specific half, and point back here for the rest.

## What it protects, and what it does not

**Protects:** the disk, once it is out of the machine. A stolen server, a disk sent back under warranty, an SSD
thrown away. The container is inert without whatever the pin needs, and the recovery passphrase is never written to
the machine.

**Does not protect:** a machine that is running. Anything that can execute code on the server as root can read the
mounted container, exactly as it can read the plaintext root filesystem. Network-bound encryption moves the secret
from the disk to the network; it does not make a compromised host safe.

**Does not protect the root filesystem.** `/nix`, `/etc`, the journal, and any key material outside the container
are all still in the clear.

## Why a file and not a partition

Carving a partition needs free space at the end of a disk that may not have any, and repartitioning a live root is
the risk this whole approach exists to avoid. A file needs no repartitioning, no `resize2fs` of the outer
filesystem, and — the point — **no initrd work at all**. It is not the root filesystem, so unlocking it is an
ordinary post-boot systemd unit. If the key server is unreachable the machine still boots, ssh still answers, and
the services that depend on the container stay down and say why.

**Disko is not involved.** Disko describes how a physical disk is partitioned at install time. This container is a
file inside a filesystem disko created — data, not layout — so disko neither knows nor needs to know about it. That
remains true when you grow it.

## Does encryption make corruption worse?

The natural fear is that a container turns a granular failure into a total one: today a bad sector costs one file,
and inside a LUKS container it might cost all of them. For the **data**, it does not. For the **header**, it does,
and that is the part worth spending effort on.

### Data damage stays exactly where it landed

LUKS2 uses `aes-xts-plain64`. XTS derives its tweak from the sector number and chains nothing across blocks, so a
flipped bit corrupts the 16-byte AES block that contains it and nothing else — not the rest of the sector, not the
next sector, not the file. Storage fails at 512- or 4096-byte granularity, which is coarser than that, so in
practice a bad sector costs the same as it costs on a plain filesystem: whichever file owns it, and no other.

The inner ext4 keeps its metadata the way the outer one does — inode tables per block group, not one central table
— so metadata damage inside the container is scoped the way it is outside.

This is a property of the mode, not of encryption in general. `aes-cbc-essiv` would smear damage across the rest of
its sector. The default does not.

### What is genuinely different

Three things, in descending order of how much they should worry you:

1. **The header is a single point of total loss.** The first 16 MiB hold the keyslots, and the keyslots hold the
   master key. Lose those bytes and every byte behind them is unreadable — not degraded, unreadable, because the key
   is gone. LUKS2 keeps a second copy of the *binary* header and falls back to it automatically, but the **keyslot
   area is not duplicated**, so that fallback does not cover the case that matters. Nothing on a plaintext ext4 has
   this shape; ext4 scatters backup superblocks across the whole volume.
2. **It is one inode in the outer filesystem.** Losing that extent tree loses everything at once, where losing a
   file's extent tree loses that file. Partly answered by the container being `fallocate`d in full: the extent tree
   is built once and never grows, in large contiguous runs, so there is no ongoing metadata churn to get caught in.
3. **Two filesystems instead of one.** Two journals, two things to `fsck`. Granularity inside is unchanged, but the
   surface area is doubled.

Item 1 is the one the module acts on, below. Items 2 and 3 are real and small, and the answer to them is the same
as the answer before there was a container: backups.

Worth saying plainly, because it is the assumption underneath the question: **neither arrangement detects
corruption.** md RAID has no checksums, and ext4 checksums metadata but never data. Granular loss today is granular
*and silent*. Encryption does not make that worse and does not make it better.

### Detecting corruption: `--integrity`, and what it can and cannot be

`setup.encryptedState.integrity` turns it on, at creation and only at creation. The decision is **format-time
only** — `cryptsetup reencrypt` cannot add integrity to an existing volume, and there is no in-place conversion —
so a machine that already has a container cannot gain it by changing the option. It would have to be recreated and
migrated into.

`cryptsetup luksFormat --integrity hmac-sha256` stacks dm-integrity under dm-crypt. Every sector gets an
authentication tag; the kernel verifies it on read and returns `EIO` rather than handing up plausible garbage.

**What it buys.** Two things, and the second is easy to miss. Silent corruption becomes a loud error at the exact
offset, so whatever reads that sector — a backup job, most usefully — fails instead of faithfully copying wrong
bytes onward. And it removes XTS's malleability: without a tag, someone who can write to the raw ciphertext can
flip a 16-byte block to random plaintext and nothing detects it.

**What it costs.**

| | |
| --- | --- |
| Space | 32 bytes of tag per sector, so **largely a function of sector size**: 32/512 = 6.25%, 32/4096 = 0.78%, plus the journal. `sectorSize` pins it rather than letting cryptsetup report what the backing device happens to say — an 8× difference that cannot be changed afterwards |
| Writes | Roughly doubled, from the journalled data+tag write. Stacks with RAID's own read-modify-write on partial stripes, so small random writes are worse than 2× |
| Format | A full-device wipe to initialise the tags, before any data moves. `--integrity-no-wipe` skips it and is a trap: unwritten sectors then read as integrity failures |
| Kernel | `DM_INTEGRITY`, plus `CRYPTO_HMAC` and `CRYPTO_SHA256`. `DM_INTEGRITY` selects `BLK_DEV_INTEGRITY`, `DM_BUFIO`, `CRYPTO_SKCIPHER` and `ASYNC_XOR` itself |
| **Growth** | **Gone.** See below — this is the cost that is easiest to miss and hardest to undo |

#### An integrity container cannot be grown

`cryptsetup` answers `Resize of LUKS2 device with integrity protection is not supported`, and there is no offline
workaround: the tag area is interleaved with the data, so extending one means rewriting the other.
`encrypted-state-grow` therefore refuses **before touching anything** — checked against the container's own header
rather than the option, since the two can disagree. Without that check it would `fallocate` the image and
`losetup --set-capacity` the loop device first and fail after, leaving both larger than the LUKS device with the
difference permanently unusable.

So the escape hatch that makes sizing a plain container forgiving is not there. Growing means a maintenance window:
stop the services, move the image aside, `encrypted-state-init` a larger one, copy in from the `*.premigrated`
directories. Size generously at creation instead.

**Measured overhead**, so generosity can be costed rather than guessed:

| container | overhead past the LUKS header |
| --- | --- |
| 64 GiB | **0.87%** |
| 256 MiB | 1.59% |

The 32-byte tag per 4096-byte sector accounts for 0.78%; the rest is dm-integrity's journal, which has a floor and
therefore dominates at small sizes. Size from the first row, not the second. `encrypted-state-init` prints the real
figure for the container it just created.

**`--integrity-no-journal` is not the way out of the write cost.** It removes the double write and leaves sectors
whose tag does not match their data after a power cut — which reads as corruption. Trading real detection for false
alarms defeats the purpose.

**Bitmap mode is not reachable from cryptsetup.** `--integrity-bitmap-mode` tracks dirty regions instead of
journalling and would give most of the detection at close to normal write speed. It is an **`integritysetup`
option** — checked against cryptsetup 2.8.6, whose entire option list contains "bitmap" zero times. Building the
stack by hand (`integritysetup format -B`, then `luksFormat` on the resulting mapper device) gets it back but costs
the reason for wanting it: a standalone integrity layer has no key available before LUKS opens, so it runs
`crc32c` — corruption detected, tampering not — while putting a bespoke layer in front of the unlock path.

**Whether it is worth it depends on one question**, and it is not the encryption one: does anything else already
detect corruption? On plain md RAID the answer is no. RAID has no checksums, ext4 checksums metadata and not data,
and a scrub counts parity mismatches without being able to say which block lied — `repair` recomputes parity *from
the data*, cementing corruption rather than fixing it. On a checksumming filesystem or with checksumming backups,
most of the benefit is already there.

## The header backup

```bash
sudo encrypted-state-header-backup                      # take or refresh it
sudo encrypted-state-header-backup --check              # exit 0 if it still matches the container
sudo encrypted-state-header-backup --export /tmp/h.age  # an encrypted copy, to carry off the machine
```

`encrypted-state-init` runs the first one for you, immediately after the clevis bind — the earliest moment the
backup is worth anything and the last moment taking it is free. It lands at
`setup.encryptedState.headerBackupPath`, 16 MiB, mode 0400.

`--export` age-encrypts it to `setup.encryptedState.headerExportRecipients` and writes the result 0644, ready for an
ordinary unprivileged `scp`. It exists because the alternative is bad in a specific way: there is no clean route for
16 MiB of root-owned binary off a server that asks for a sudo password — `ssh host sudo cat` cannot authenticate,
and `ssh -t` puts the terminal in cooked mode and mangles the stream — so by hand it means copying the plaintext to
`/tmp`, scp-ing it, and remembering to shred it. Declaring the recipients in configuration also removes the failure
where a recipient is mistyped at the prompt, the file looks perfect, and nobody discovers it opens for no one until
a recovery.

**It is key material.** It cannot be decrypted by itself, but it holds the same keyslots the container does:
whoever has it plus either the recovery passphrase or reach to the key server opens the volume. Keep it with the
recovery passphrase, not beside the container.

**A local copy is half the answer.** It survives a botched `luksKillSlot`, a bad `luksChangeKey` and a corrupted
first 16 MiB. It does not survive the disk. Copy it somewhere the loss of this machine does not reach — that half
no module can do for you.

### It goes stale, and stale is dangerous

The backup describes the keyslots **as they were when it was taken**. Restoring an old one revives a keyslot that
was killed since and drops one that was added — the first of which is a security problem, not an inconvenience.

Re-take it after anything that writes the header: `luksAddKey`, `luksKillSlot`, `luksChangeKey`, `clevis luks bind`
or `unbind`. Every one of those bumps the LUKS2 seqid, and both `--check` and `encrypted-state-status` compare the
backup byte for byte against the front of the container, so none of them can slip past:

```text
container:
  header     /var/lib/encrypted-state-header.bak STALE - the keyslots have changed since it was taken
```

`encrypted-state-status` reports this but does **not** count it toward its exit status. That status answers "is
application state coming from the container", which alerting acts on immediately; folding a piece of paperwork into
it would page on a healthy machine and teach everyone to ignore the signal.

### Nobody remembers a five-command list, so the machine watches instead

Those five commands are run once every few years. Expecting anyone to think "and now the header backup" afterwards
is how the backup silently stops being one. So `encrypted-state-header-check.timer` runs daily, compares, and
starts `setup.encryptedState.headerNotifyUnits` when the answer is wrong — normally the same notifier the machine
uses for everything else, instanced on this unit so the message carries this check's own explanation.

It alerts **every day until it is fixed**, unlike the outage notification which fires once. The difference is that
an outage ends by itself and this does not, so the thing to guard against is not a burst of messages but a single
one that gets scrolled past.

The check unit deliberately **succeeds** when it finds a stale backup. A failed unit means one thing on these
machines — `systemctl --failed` and `degraded` mean application state is not coming from the container, act now —
and lending that alarm to a piece of paperwork is how an alarm stops being read.

### A container created before this existed has no backup

The header backup was added after the first machines were migrated. On those, `encrypted-state-status` says
`MISSING` until you run the command once. Nothing else is wrong with them.

## The failure mode this is built around

If the container is not mounted, a service's state directory is an empty directory on the root filesystem. A
database server, finding no data where its data should be, does not report an error — it initialises a brand new
empty one over the top of the mountpoint and reports success. The service would then be serving nothing, and the
only signal would be somebody saying their data is gone.

So every unit named against a path in the container gets:

- `RequiresMountsFor=<path>`, which is `Requires=` plus `After=` on the bind mount — the unit cannot start at all
  while the container is locked; and
- a `checkMountScript` in `preStart`, which catches what `RequiresMountsFor` cannot see: a mount unit that reports
  success over a filesystem that is wedged, which on a loop-backed device is a real possibility.

**This is why the unit lists matter.** A unit missing from a path's list is a unit that will one day come up against
an empty directory and call it a fresh install. An evaluation-time assertion checks that every name written there
actually exists on the machine, because a misspelled unit name attaches the guard to nothing and warns nobody.

The converse is worth stating too: a unit that does *not* read the path should not be listed. A backup job that only
ships an already-taken archive offsite reads the backup mount, not the container — guarding it just fails an offsite
copy that had nothing to do with the outage, and alerts on it.

## Rehearsing the failure, on purpose

Everything above is a claim about what happens when the key server is gone, and nothing proves it except taking the
key server away. `setup.encryptedState.simulateKeyServerOutage = true` does that, on a VM:

```nix
setup.encryptedState.simulateKeyServerOutage = true;   # VMs only, asserted
```

It installs one `iptables -I OUTPUT -d <key server> -j DROP` rule, with the address parsed out of `clevisConfig`
so the rehearsal cannot end up blocking a box the machine does not actually unlock against.

Two choices in that sentence are the whole point:

- **A firewall rule, not a route.** Nothing typed at a shell survives a reboot here — a route is gone on the next
  boot, and NixOS keeps `/etc/systemd/system` in the store, so there is nowhere to persist a unit that re-adds one
  either. The rehearsal has to be in the configuration or it is not a rehearsal of a boot.
- **DROP, not reject.** A blackhole route and a rejection both fail *immediately*, which the unlock handles
  trivially. A server that is merely switched off gives silent drops and a TCP connect that hangs until the kernel
  gives up — and it is the waiting, not the failing, that can drag a boot into the retries. That is the case
  `DefaultDependencies=no` exists to survive, so that is the case to rehearse.

Rebuild, reboot, and the machine should come up **promptly** with its databases down. Check it with:

```bash
encrypted-state-status               # what is open, what is bound, what is down. Exits 1 when degraded.
journalctl -b | grep "ordering cycle"             # nothing
```

`systemctl --failed` should name `encrypted-state-unlock.service`, and `systemctl is-system-running` should say
`degraded`. Also check that no guarded service is `active`: one that is has started on the empty directory
underneath, which is the accident the whole design is against — `encrypted-state-status` lists them per path.

Then lift it **without a rebuild** and watch the machine heal on its own:

```bash
sudo iptables -D OUTPUT -d <key server> -j DROP
```

Within `retryIntervalSeconds` the container should unlock and the services start with nothing else typed. That is
the other half of the property — an outage that ends must not need an operator — and it is only observable from
inside a rehearsed outage.

## Why the retry is a timer

Because the obvious design is wrong in a way that took a rehearsal to see. The unlock used to retry inside its own
`ExecStart`: twenty attempts, fifteen seconds apart, which reads as exactly what a boot-time network dependency
should do. On 2026-08-12 a machine was cut off from its key server and it cost four things at once.

A unit that is retrying is `activating`, not `failed`. So:

- **`systemctl --failed` was empty.** For the whole outage.
- **`systemctl is-system-running` said `starting`**, indefinitely — the queued job meant systemd never considered
  the boot finished. A machine down for an hour looked like one that booted forty seconds ago.
- **`OnFailure=` never fired**, so there was no way to alert on it at all.
- **`nixos-rebuild switch` blocked** on the unlock's start job and had to be killed from the serial console.

None of that is fixable by tuning the loop; it is what an internal loop *means*. So the unlock now makes exactly
one bounded attempt and fails, and `encrypted-state-retry.timer` is what tries again. The failed state persists
between ticks, which is what makes every one of those four work.

The cost is real and worth stating: each tick starts the unlock again, which clears `failed` for as long as the
attempt takes. `systemctl --failed` can therefore be briefly empty during a genuine outage, which is why
`retryIntervalSeconds` defaults to five minutes rather than thirty seconds, and why `encrypted-state-status` reads
the mounts instead of asking systemd how the units feel.

### Opening the container is not the same as healing the machine

The retry starts the guarded units itself, and it has to, for a reason that is not obvious and cost a rehearsal to
find. When the unlock fails at boot, every guarded unit's job is **cancelled** with result `dependency` — not
queued, cancelled. `RequiresMountsFor` is a condition on starting, not a trigger to start. So a container that
opens twenty minutes later brings up the mounts and *nothing else*: `systemctl --failed` is empty,
`encrypted-state-status` says OK because the paths genuinely are served from the container, and thirty services sit
there dead.

The in-unit retry hid this by accident. While the unlock sat in `activating`, the dependent jobs stayed **queued**,
so a late success let them all proceed. That accident was doing real work, and failing fast threw it away. So after
a successful heal the retry walks the declared units and starts anything loaded and not already running, with
`--no-block` so systemd sequences them exactly as a boot would.

It only does this when an outage was actually recorded. On a routine tick of a healthy machine it starts nothing —
otherwise every timer-driven backup in the path lists would run every five minutes forever.

### Alerting

`outageNotifyUnits` are started once the container has been down for `outageNotifyAfterSeconds`, **once per
outage**. Not on the first failure, because a power cut brings a machine and its key server back at their own paces
and an alert for every one of those is an alert that gets muted. Not on every retry, for the same reason. The stamp
files live in `/run`, so a reboot starts the clock — and the notification — again.

`systemctl --failed` also works between the first deploy and `encrypted-state-init`, for a different reason: there
is no container file, the retry script treats that as an operator action rather than a fault, and nothing restarts
the unlock at all.

## Adding a service

One line, in the service's own module, next to the units it defines:

```nix
setup.encryptedState.paths."/var/lib/mything" = [
  "mything.service"
  "mything-setup.service"     # the setup unit too
  "mything_backup.service"    # and the backup job, if it reads the live directory
];
```

`paths` is an ordinary attribute set of lists, so it merges the way any NixOS option does. Two modules may name the
**same** path and their lists are concatenated — which is what lets a service and its backup job be declared in
separate files without either knowing about the other. There is no central list to keep in step, and deleting a
service takes its entry with it.

Then create the directory inside the container and let the service populate it, or migrate an existing one:

```bash
sudo encrypted-state-migrate /var/lib/mything
```

If the path does not exist yet, `migrate` just creates it empty inside the container.

## What must not go in the container

Two shapes will break the boot if you put them in, and neither breaks it loudly. Both were found by the checks, not
by reading the code.

**A path with an ordinary mount nested inside it.** Say `/var/lib/foo/data` is a network mount, and therefore a
member of `local-fs.target`. systemd orders a nested mount after the one it sits inside, so binding `/var/lib/foo`
would put a network-unlocked mount *between* `local-fs.target` and one of its own members. Best case that is an
ordering cycle; worst case `local-fs.target` — and so `sshd` — waits out the unlock retries on a machine whose key
server is dead, which is precisely the situation you need ssh for. Bind the sibling that actually holds the secrets
instead.

**A path or socket unit watching something inside it.** systemd gives a `PathExists=` unit an automatic
`RequiresMountsFor`, and a path unit is `Before=paths.target`, which is part of `basic.target` — the same problem by
a different route. Fix it with `DefaultDependencies=no` on the path unit, which keeps the automatic mount
requirement and drops the early-target ordering.

The general rule: **nothing that `basic.target` or `local-fs.target` waits for may end up waiting on this
container.** The unlock service and the mounts all carry `DefaultDependencies=no` for that reason, but that only
covers the units this module creates — anything already ordered against a path you add is your problem, and the
check is what finds it.

## What is underneath the bind mounts

Every bound path has a directory under it that the mount hides, and it is not empty. `systemd-tmpfiles-setup` and
services' `StateDirectory=` run at sysinit, long before the container can be unlocked, so they create the usual
skeleton at the real path; the bind mount then covers it. On one machine, six of eleven bound paths had something
underneath — `forgejo/{repositories,data,custom/conf,log,dump}`, a Maildir's `{tmp,new,cur}`, `traefik/letsencrypt`,
two `postgres/` directories — and **zero regular files with any content**. It costs a few inodes and nothing else.

**But it is why the guards are not paranoia.** If the container fails to unlock, a service does not find a bare empty
directory that might make it hesitate. Forgejo finds `repositories/`, `data/` and `custom/conf/` already there: a
plausible, empty, freshly-installed-looking tree. That is exactly the shape `RequiresMountsFor` plus the
`checkMountScript` preStart exist to stop a service from starting on, and the reason "an empty directory looks like
a fresh install" is a real failure rather than a theoretical one.

### Wiping what is under a mount

Anything written to a path while the container was not bound is still there, hidden. Usually that is a harmless
directory skeleton; after gmktec1's first migration it was a whole abandoned Postgres cluster. To remove it, work
inside a private mount namespace so the unmount is yours alone and the running services never see it.

**Look first.** The two commands differ by one line, and the destructive one is only safe because the `&&` chain
proves the unmount happened:

```bash
sudo unshare --mount --propagation private bash -c '
  umount /var/lib/postgresql &&
  ! mountpoint -q /var/lib/postgresql &&
  ls -la /var/lib/postgresql'
```

If that lists what you expect to delete — and nothing you recognise as live data — repeat it with the removal:

```bash
sudo unshare --mount --propagation private bash -c '
  umount /var/lib/postgresql &&
  ! mountpoint -q /var/lib/postgresql &&
  rm -rf /var/lib/postgresql/* &&
  ls -la /var/lib/postgresql'
```

Never run the `rm` without the `umount &&` in front of it in the same shell. With the mount in place that command
deletes the live data instead, and the two situations look identical from a prompt.

### Looking under a mount without unmounting it

Two ways, neither of which disturbs anything running.

`unshare --mount` gives a shell its own copy of the mount table, and `--propagation private` stops anything done
there travelling back:

```bash
mapfile -t binds < <(findmnt -rno TARGET,SOURCE \
  | awk '$2 ~ /encrypted-state/ && $1 != "/encrypted" {print $1}' | sort -r)

sudo unshare --mount --propagation private -- bash -c '
  for m in "${binds[@]}"; do umount "$m"; done   # invisible outside this namespace
  for m in "${binds[@]}"; do find "$m" -mindepth 1; done
'
```

`sort -r` matters: deepest first, so a nested mount comes off before the one it sits inside.

Or, without namespaces — `mount --bind` is **not** recursive, so binding a parent gives you a view with the
submounts absent:

```bash
sudo mount --bind /var/lib /mnt/peek     # /mnt/peek/vaultwarden is the UNDERLYING directory
sudo umount /mnt/peek
```

## Where the commands come from

`encrypted-state-init`, `encrypted-state-migrate`, `encrypted-state-grow`, `encrypted-state-status`,
`encrypted-state-header-backup` and `encrypted-state-close` are put on the **machine's** `PATH` by the module, for
**root**, whenever `setup.encryptedState.enable` is true. So every
`sudo encrypted-state-…` below is typed on the server itself, over ssh, and needs no repository checkout.

They are deliberately not in any devshell. Each one is generated with that machine's image path, mapper name, size
and pin configuration baked in as environment variables — a copy on a workstation would either have the wrong values
or none, and there is no container there to act on anyway.

## Growing the container

**Not possible if the container was created with `integrity`** — `encrypted-state-grow` refuses, and
[the reason](#an-integrity-container-cannot-be-grown) is that cryptsetup cannot resize such a volume at all. The
rest of this section is about containers without it.

Online, with the services running, and **nothing to do with disko**:

```bash
sudo encrypted-state-grow 128G
```

The size is the new **total**, not an increment. Behind it:

1. `fallocate` extends the backing file — existing bytes untouched.
2. `losetup --set-capacity` tells the loop device, which cached the old size when it was attached.
3. `cryptsetup resize` grows the dm-crypt mapping. The volume key comes from the kernel keyring; if it is not there
   the script asks the pin instead of prompting.
4. `resize2fs` grows the filesystem. ext4 grows online, which is what makes the whole thing downtime-free.

Then update `setup.encryptedState.size` in the machine's configuration so it matches what is on disk.

**Shrinking is not automated.** It means shrinking the filesystem first, offline, and getting the arithmetic wrong
truncates data. If it is ever genuinely needed, create a smaller container alongside and migrate into it.

**It refuses to grow past the free space** on the outer filesystem, and it refuses to "grow" to something smaller.

### Why it is fully allocated and not sparse

`fallocate` takes the whole size immediately. A sparse container on a filesystem that later fills up returns ENOSPC
to writes coming from *inside* the container — so the error surfaces on a database, at fsync time, caused by
something entirely unrelated filling the disk. Taking the space up front means that failure happens once, at
creation, when it is harmless.

For the same reason the container is mounted `nodiscard` and opened without `--allow-discards`: discards from inside
would travel down through dm-crypt and the loop device and punch holes in the backing file, quietly turning the
fully-allocated container back into a sparse one.

## Performance

Measured with `cryptsetup benchmark` on the gmktec hardware (Intel N150, AES-NI, four cores):

| | throughput |
| --- | --- |
| `aes-xts` 512-bit, one core | 2381 MiB/s encrypt, 2246 MiB/s decrypt |
| Its NVMe (GVR512, PCIe 3.0 **x2**) | ~1500 MiB/s ceiling, less on sustained writes |

A single core encrypts faster than the disk can move bytes, so sequential I/O loses nothing measurable. Two
second-order effects are handled explicitly:

- **dm-crypt's workqueues** add per-I/O latency, which is what a fsync-heavy Postgres feels. The container is opened
  with `--perf-no_read_workqueue --perf-no_write_workqueue`, which exist for exactly this case: fast storage plus
  hardware AES. The test asserts both flags are present in the live dm table, because a silently dropped flag looks
  identical to one that works.
- **Double page-caching.** A file-backed container caches every block twice — once for the inner filesystem, once
  for the backing file — on a machine whose RAM is already the scarce resource. `losetup --direct-io=on` removes it.
  If the outer filesystem does not support `O_DIRECT` the unlock falls back and says so in the journal rather than
  refusing to boot.

### Why argon2id is pinned

`cryptsetup` self-calibrates the KDF against memory available **at the moment of formatting**, on the machine doing
the formatting. On an idle server it readily picks 871 MiB. But unlocking happens post-boot on a machine already
running everything it serves, so a header calibrated against an idle box can demand memory a busy one cannot spare —
and fail at exactly the worst time. `pbkdfMemoryKiB` defaults to 256 MiB, which is still far beyond brute-force
reach for a 32-byte random passphrase and always fits.

## Creating it on a new machine

### 1. First deploy, with `bindState = false`

```nix
setup.encryptedState = {
  enable = true;
  bindState = false;   # nothing is bound yet
  size = "64G";
  clevisConfig = ''{"url":"http://…","thp":"…"}'';
};
```

`nixos-rebuild switch`. Nothing changes for the running services: they keep using the plain root filesystem.

**Expect `encrypted-state-unlock.service` to be failed after this deploy.** There is no container yet, so it cannot
succeed, and it says so: *"$IMAGE does not exist. The container has never been created on this machine. Run
encrypted-state-init."* `systemctl --failed` will be non-empty until step 2. The retry loop deliberately does not
run in this state — it is gated on the container file existing, so a missing container does not spin every thirty
seconds through however long it takes you to get to the next step.

**The two deploys are not an accident.** Enabling the container and binding the paths at once would mount empty
directories over live data — the services would come up against nothing and the databases would initialise
themselves on top of the mountpoints.

### 2. Create the container

```bash
sudo encrypted-state-init
```

It allocates the file, formats LUKS2 with a pinned KDF, binds a second keyslot to the pin, **verifies the binding
actually opens** before returning, makes the filesystem, and creates the declared directories inside.

It then **starts `encrypted-state.target`**, so the container is mounted at `mountPoint` when it returns and the
next step can run immediately. Everything above that point is opened and closed by hand; without this hand-off the
container would be closed again and `encrypted-state-migrate` would answer *"the container is not mounted"*. Going
through the target rather than mounting it directly is deliberate — it exercises the same unlock unit and mount
unit that every later boot uses, and clears the `failed` state the unlock unit has been in since step 1.

If `bindState` is already `true` it refuses to start the target and exits non-zero, because binding the empty
directories of a brand-new container over live data is the accident the two deploys exist to prevent. The container
is still created in that case — do not run `encrypted-state-init` again, fix `bindState` and start the target.

It prints the **recovery passphrase once** and stores it nowhere. Record it before answering the prompt, in the two
places the machine's own repository names — one of them offline and off this machine. It cannot go in a password
manager whose database is itself inside the container.

It refuses to touch an existing container. Re-running `luksFormat` on one that holds data destroys every byte in it.

### 3. Migrate

```bash
sudo encrypted-state-migrate --dry-run   # what would move, and how much
sudo encrypted-state-migrate
```

Per path: stop the units, `rsync -aHAX --numeric-ids`, **verify** with a second itemising dry-run pass that must come
back empty, then rename the original to `<path>.premigrated` and create an empty mountpoint with the same ownership
and mode. The originals stay on disk, so a migration that went wrong is undone by renaming them back rather than by
restoring a backup.

The services are down from here until the next switch. That is the maintenance window, and it is as long as the copy
takes.

### The window between the two deploys

Once `encrypted-state-migrate` has moved a path, that path is an **empty directory with nothing guarding it**:
`bindState` is still false, so there is no mount for `RequiresMountsFor` to hold anything back. A service that
starts in this window finds no data where its data should be, and a database answers that by initialising a new
one. On gmktec1's first real migration exactly that happened — something pulled `postgresql.service` seven minutes
after its cluster had been copied into the container, and `initdb` built a fresh one on the root filesystem.
Nothing was lost, because the real cluster was already in two places, but it is the accident this whole design
exists to prevent, arriving through the one gap where the guards do not apply.

So the migration closes the gap itself, in two ways:

- **It stops each path's triggering units** — the `.timer`s and `.path`s — before stopping the services, and leaves
  them stopped. Stopping a service while its timer is armed only means it starts again a few minutes later, in the
  middle of the copy. That is not hypothetical either: a mailcache sync fired mid-rsync, wrote a lock file, and the
  verification correctly refused to move a copy that no longer matched the original.
- **It drops a `ConditionPathIsMountPoint` into `/run/systemd/system/<unit>.d`** for every unit of a moved path.
  Nothing can start on the empty directory, including something running as root, and the condition becomes true by
  itself the moment the second deploy binds the path. `encrypted-state-resume` then removes the drop-ins and starts
  what was held back.

`systemctl mask --runtime` was the obvious way to do that and it does not work on NixOS: `/etc/systemd/system`
outranks `/run` for unit *files*, and NixOS puts every unit in `/etc`. The mask gets created and ignored. Drop-ins
are the exception — they are collected from every search path rather than shadowed — which is why the guard is
shaped this way.

`encrypted-state-status` reports these units as `held`, not `down`, and exits non-zero while any remain.

### 4. Second deploy, with `bindState = true`

```bash
nixos-rebuild switch
```

The bind mounts come up, the services start on data inside the container, and from now on they cannot start without
it.

### 5. Verify, then clean up

Check the services, then reclaim the space:

```bash
sudo encrypted-state-migrate --cleanup
```

It refuses to delete a `.premigrated` copy whose path is not actually a bind mount yet — while the container is not
carrying the load, that copy is still the only copy.

## Recovering it

### The key server is up (normal)

Nothing to do. `encrypted-state-unlock.service` asks the pin at every boot, retrying while the network comes up.

### The key server is down but will come back

The machine boots, ssh works, and everything with state in the container stays down.
`encrypted-state-retry.timer` keeps trying, so it heals itself once the pin answers. Nothing to do but fix the key
server. The unlock unit sits in `failed` in the meantime, deliberately — that is the report, not a thing to clear.

### The key server is gone, and you have the passphrase

```bash
loop=$(sudo losetup --find --show /var/lib/encrypted-state.img)
sudo cryptsetup open "$loop" encrypted-state      # prompts; type the recovery passphrase
sudo mount /dev/mapper/encrypted-state /encrypted
```

Type it at the prompt rather than piping it in. `--key-file=-` takes stdin **literally, including a trailing
newline**, so `cat passphrase.txt | cryptsetup open --key-file=-` fails with "No key available" — the same message a
genuinely wrong passphrase gives. The interactive prompt strips the newline, and so does `encrypted-state-init` when
it reads the passphrase.

### The key server is gone and you want the bound keyslot back

Rebuild the key server from its backup. The JWE lives in the container's own LUKS2 header, so it travels with the
container:

```bash
sudo cryptsetup token export --token-id 0 /var/lib/encrypted-state.img | jq -r .jwe
```

A rebuilt server with the original keys, answering at the **original address**, unlocks it unchanged — the URL is
inside the JWE's integrity-protected header and cannot be rewritten.

### The header is damaged and nothing opens the container

The symptom is `Device … is not a valid LUKS device`, or an unlock that fails with every key you have while the
container file is plainly still there. Put the header back:

```bash
sudo systemctl stop encrypted-state.target
sudo cryptsetup luksHeaderRestore /var/lib/encrypted-state.img \
  --header-backup-file /var/lib/encrypted-state-header.bak
sudo systemctl start encrypted-state.target
```

**This is the dangerous direction.** It overwrites the live keyslots with the ones in the file, so a stale backup
silently reverts every keyslot change made since it was taken. Check what you are about to write first — the backup
file is a LUKS device in its own right, so it dumps like one:

```bash
sudo cryptsetup luksDump /var/lib/encrypted-state-header.bak
```

Two keyslots and a `clevis` token is what a healthy one looks like. The data behind the header is untouched by any
of this: restoring a header does not rewrite a single sector of the volume.

### You have neither

The container is gone. That is the design: the passphrase and the key server's own backup are the only two ways in.
This is also why the header backup is worth taking — it is the one artifact that turns "the first 16 MiB were
damaged" from that sentence into a two-minute repair.

## Tests

Two files. `tests/encrypted-state.nix` drives the mechanism end to end against a fixture key server: creation, binding,
migration, the bind mounts, the dm-crypt performance flags, direct I/O, survival across a reboot, online growth,
**the service staying down with the key server gone**, and recovery by passphrase.

The header backup is tested in the direction that matters. Asserting that a file exists proves nothing, so the test
adds a keyslot, watches `--check` and `encrypted-state-status` both report `STALE`, restores the backup, and
confirms the original two keyslots and the clevis token came back. Everything after that subtest unlocks through
the restored header — so if the restore were not a working one, the rest of the file would not pass.

The module takes any clevis pin; the fixture uses the tang one because it is the only pin that can be stood up
inside a test VM.

The ordering-cycle assertion earns its place: a mount unit under `/` is `Before=local-fs.target` by default, and this
one requires a service that needs the network, which closes a loop through `sysinit.target`. systemd resolves a cycle
by **deleting one of the jobs** and booting anyway. During development it chose `systemd-tmpfiles-setup.service`, so
every tmpfiles rule on the machine silently did not run. The fix is `DefaultDependencies=no` on the mount units with
the ordering written out explicitly; the test is what stops it coming back.

`tests/encrypted-state-integrity.nix` covers `integrity` separately, because formatting with it wipes the whole
container and changes the timing of everything downstream. Its one subtest that matters is **"a corrupted sector is
refused, not returned"**: a byte is written into the raw container behind dm-crypt's back and the read must come
back `EIO`. Every other assertion there would pass with integrity silently doing nothing — the container would
format, bind, unlock, mount and serve identically — so the paired control that follows it is not optional. It
repeats the same damage on a plain LUKS2 volume built the same way and asserts the bytes come back **changed and
without an error**, which is both the status quo and the proof that the assertion above is about integrity rather
than about `dd`. Neither uses a filesystem: a pattern is written straight to the mapper, so a refused read cannot
be ext4 noticing its own metadata is wrong. It is also where the resize limitation was found.

A superproject should add its own check driving the real machine's configuration. Thirty units and a nested network
mount produce failures that a two-unit fixture structurally cannot.
