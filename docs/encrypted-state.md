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

Rebuild, reboot, and the machine should come up **promptly** with its databases down:

```bash
systemctl is-system-running          # degraded, not starting - it did not wait
systemctl status encrypted-state-unlock.service   # failed, having tried unlockAttempts times
findmnt --target /var/lib/<service>  # the root filesystem, not the container
journalctl -b | grep "ordering cycle"             # nothing
```

And check that no guarded service is `active`. One that is has started on the empty directory underneath, which is
the accident the whole design is against.

Then lift it **without a rebuild** and watch the machine heal on its own:

```bash
sudo iptables -D OUTPUT -d <key server> -j DROP
```

`encrypted-state-retry` restarts every 30 seconds, backing off to five minutes, so the container should unlock and
the services start with nothing else typed. That is the other half of the property — an outage that ends should not
need an operator — and it is only observable from inside a rehearsed outage.

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

`encrypted-state-init`, `encrypted-state-migrate`, `encrypted-state-grow` and `encrypted-state-close` are put on the
**machine's** `PATH` by the module, for **root**, whenever `setup.encryptedState.enable` is true. So every
`sudo encrypted-state-…` below is typed on the server itself, over ssh, and needs no repository checkout.

They are deliberately not in any devshell. Each one is generated with that machine's image path, mapper name, size
and pin configuration baked in as environment variables — a copy on a workstation would either have the wrong values
or none, and there is no container there to act on anyway.

## Growing the container

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
`encrypted-state-retry.service` keeps trying, so it heals itself once the pin answers. Nothing to do but fix the key
server.

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

### You have neither

The container is gone. That is the design: the passphrase and the key server's own backup are the only two ways in.

## Tests

`tests/encrypted-state.nix` drives the mechanism end to end against a fixture key server: creation, binding,
migration, the bind mounts, the dm-crypt performance flags, direct I/O, survival across a reboot, online growth,
**the service staying down with the key server gone**, and recovery by passphrase.

The module takes any clevis pin; the fixture uses the tang one because it is the only pin that can be stood up
inside a test VM.

The ordering-cycle assertion earns its place: a mount unit under `/` is `Before=local-fs.target` by default, and this
one requires a service that needs the network, which closes a loop through `sysinit.target`. systemd resolves a cycle
by **deleting one of the jobs** and booting anyway. During development it chose `systemd-tmpfiles-setup.service`, so
every tmpfiles rule on the machine silently did not run. The fix is `DefaultDependencies=no` on the mount units with
the ordering written out explicitly; the test is what stops it coming back.

A superproject should add its own check driving the real machine's configuration. Thirty units and a nested network
mount produce failures that a two-unit fixture structurally cannot.
