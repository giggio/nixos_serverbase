# Disaster Recovery — Orange Pi 4 Pro (NixOS, Allwinner A733 / sun60iw2)

**Read this when the board no longer boots.** It assumes you have not touched this project in a long time and remember nothing.
It walks from "the board is dead" to "the board boots again", preferring the cheapest repair that will work.

> **If you read only one thing:** this board boots from the **SD card** and runs from the **NVMe SSD**. The SD card can never be
> removed — the SoC's boot ROM can only fetch the first-stage loader from SD raw sectors, never from PCIe. Almost every failure
> is repaired by rewriting something on the SD card, while the SSD (which holds every NixOS generation you have ever built) is
> left untouched.
>
> **If the card itself is dying or too small, you do not need to reinstall.** Build the boot-only image
> (`nix build .#opi4proboot_img`), flash it to a new card, swap it in. It reproduces the whole boot chain and never touches the
> NVMe. See **§7**.

---

## 0. What you need before you start

- The board, with both its SD card and its NVMe SSD.
- A PC with an SD card reader (any Linux machine; `nix` is needed only for §3b, §5b and §7).
- A checkout of this NixOS configuration repository. It pins every source by hash, so it rebuilds identically years later.
- A **serial console** on the board's debug UART header at **115200 baud, 8N1**. This is not optional — until Linux is running
  there is no other output channel. On the PC: `sudo picocom -b 115200 /dev/ttyUSB0` (or `screen /dev/ttyUSB0 115200`).

> Serial troubleshooting, learned the hard way: if you get **nothing at all**, unplug and replug the USB-serial adapter before
> concluding the board is dead. A wedged adapter looks exactly like a wedged board. Also fully power-cycle the board (unplug,
> wait ~20 seconds, replug) — these Allwinner boards can latch into a state where the boot ROM does not re-run on a warm reset.

Throughout, `/dev/sdX` means the **whole SD card device** (e.g. `/dev/sdb`, or `/dev/mmcblk0` on a built-in reader).
**Confirm it with `lsblk` before every `dd`.** Writing to the wrong device destroys your PC's disk.

### The disk layout

**SD card** — the boot device. Two partitions, plus a bootloader region in raw sectors that no filesystem shows you:

| Where | Contents |
|---|---|
| raw offset **8 KiB** | `boot0_sdcard.fex` — Allwinner's DRAM-init blob, read directly by the SoC's boot ROM |
| raw offset **16400 KiB** | `boot_package.fex` — U-Boot + BL31 (secure monitor) + SCP firmware, read by boot0 |
| partition 1 — vfat, label `FIRMWARE`, starts at 48 MiB, **bootable flag set** | `Image` (kernel), `uInitrd` (initrd), `allwinner/sun60i-a733-orangepi-4-pro.dtb`, **`boot.scr`** |
| partition 2 — ext4, label `NIXOS_SD` | Leftover installer root. **Not used by the running system.** Ignore it. *Absent entirely on a card written by the boot-only image (§7) — that is normal, not damage.* |

**NVMe SSD** — the root filesystem:

| Where | Contents |
|---|---|
| `/dev/nvme0n1p1` — ext4, label `NIXOS_ROOT`, partlabel `disk-main-nixos` | `/`, `/nix/store`, and **every NixOS generation** |

Two things about this layout are load-bearing and easy to break:

1. **`boot.scr` lives on the FAT partition (partition 1), not on any ext4 root.** Older cards had it at `/boot/boot.scr` on
   partition 2. If you are looking at an old card, that is why.
2. **The bootable flag must be on partition 1.** U-Boot's distro-boot scan runs `part list mmc 0 -bootable` and only searches
   partitions in that list for `boot.scr`. If the flag is on partition 2 (the nixpkgs default), U-Boot will never find the boot
   script. Fix with `sudo sfdisk --activate /dev/sdX 1`.

---

## 1. First: work out *how far* the boot gets

Power the board with serial attached and read the output. Do not skip this — the fix depends entirely on where it stops.

| What you see on serial | What it means | Go to |
|---|---|---|
| **Nothing at all** | Replug the serial adapter; fully power-cycle the board (20 s unplugged). If still silent, see §2's checks — the raw bootloader may be missing. | **§2**, then **§3** |
| `HELLO! BOOT0 is starting!` then it stops or loops | The bootloader region is damaged or wrong. | **§3** |
| U-Boot banner (`U-Boot 2018.07-g…`) appears, then `undefined instruction`, or a hang right after `Starting kernel ...` | U-Boot itself is bad. | **§3** |
| U-Boot runs but cannot find `boot.scr`, or reports `Bad Data CRC`, or cannot load `Image` | Bootloader fine; the boot files or the bootable flag are wrong. | **§4** |
| Kernel banner appears, then stage 1 fails: cannot find root, drops to an initrd emergency shell | Boot files fine; the NVMe root is unreachable or the generation is broken. | **§5** |
| Boots, but the system is broken (services failing, bad config) | Roll back to a previous generation. | **§5** |

**The key insight for this board:** `/nix/store` on the NVMe almost always survives, and it still contains **every previous
generation**. So recovery is nearly always "point the boot chain back at a generation that worked" (§5), not "rebuild
everything".

---

## 2. Confirm the bootloader is physically on the card

Do this when you get no output at all, or output that stops before U-Boot. It takes two minutes and tells you whether the raw
bootloader region is intact. Put the card in your PC:

```bash
lsblk                                   # identify the card, e.g. /dev/sdb

# boot0 must be at 8 KiB. A valid boot0 carries the "eGON.BT0" magic near its start.
sudo dd if=/dev/sdX bs=1k skip=8 count=1 2>/dev/null | xxd | head -4

# the boot package must be at 16400 KiB. It starts with the TOC1 name "sunxi-package".
sudo dd if=/dev/sdX bs=1k skip=16400 count=1 2>/dev/null | xxd | head -8

# the bootable flag must be on partition 1 (look for the "*" in the Boot column)
sudo sfdisk --list /dev/sdX
```

**Expected:** `eGON.BT0` in the first dump; `sunxi-package` followed by `u-boot` in the second; a `*` against partition 1.
A card written by the boot-only image (§7) shows **one** partition and nothing else; an installer-written card shows two. Either
is fine — what matters is that partition 1 carries the `*`.

- Missing magic, or all zeros → the bootloader is gone. Go to **§3**.
- Both present and the flag is on partition 1 → the bootloader is fine; your problem is later. Go to **§4** or **§5**.
- Both present but the flag is on partition **2** → that alone will prevent boot. Fix it: `sudo sfdisk --activate /dev/sdX 1`.

---

## 3. Repair the bootloader (raw sectors)

Do this when the board dies before or inside U-Boot: no U-Boot banner, `undefined instruction`, or a hang immediately after
`Starting kernel ...`.

Nothing here touches any filesystem — you are only rewriting raw sectors that live before partition 1.

There are three sources for a working bootloader. **§3c is easiest if the board still boots at all**; **§3a is the fastest cold
repair**; **§3b is the from-source path.**

### 3a. Restore the known-good bootloader stored in git

Two verified-bootable bootloader files were committed early in this project and later removed from the working tree. They are
still in git history, in commit **`641213b381e93917ee1c23fb0b2c1c05719170b7`**:

- `modules/blobs/armbian-boot0_sdcard.fex`
- `modules/blobs/armbian-boot_package.fex`

Extract them without touching your working tree:

```bash
cd /path/to/your/nixos-config
mkdir -p ~/opi4pro-recovery

git show 641213b381e93917ee1c23fb0b2c1c05719170b7:modules/blobs/armbian-boot0_sdcard.fex \
  > ~/opi4pro-recovery/boot0_sdcard.fex
git show 641213b381e93917ee1c23fb0b2c1c05719170b7:modules/blobs/armbian-boot_package.fex \
  > ~/opi4pro-recovery/boot_package.fex
```

**Verify before flashing.** `boot_package.fex` must be exactly **1392640** bytes:

```bash
stat -c '%s %n' ~/opi4pro-recovery/boot_package.fex     # must print: 1392640 ...
```

If you still have `toc1_extract.py` from this project, a stronger check — it must list exactly three items (`u-boot`, `monitor`,
`scp`):

```bash
python3 toc1_extract.py list ~/opi4pro-recovery/boot_package.fex
```

Write them to the raw offsets:

```bash
lsblk                                                  # CONFIRM the device
sudo dd if=~/opi4pro-recovery/boot0_sdcard.fex  of=/dev/sdX bs=1k seek=8     conv=notrunc,fsync
sudo dd if=~/opi4pro-recovery/boot_package.fex  of=/dev/sdX bs=1k seek=16400 conv=notrunc,fsync
sync
```

`conv=notrunc` means "do not truncate the destination" — essential, or you would wipe the rest of the card. `seek=` counts in
`bs` units, so `bs=1k seek=16400` is byte offset 16400 × 1024.

**Check it worked:** boot with serial. You should see a U-Boot banner. This binary is Armbian's build, so it reads
`U-Boot 2018.07_armbian-…` and its countdown is ~1 second rather than 5 — expected and harmless. Your boot files are untouched,
so it will try to boot your system next; continue to §4/§5 if it still fails.

### 3b. Rebuild the bootloader from source

The preferred path when you have time — everything is built from pinned sources.

```bash
cd /path/to/your/nixos-config

# If HEAD is what broke the board, check out the last commit you know booted:
git log --oneline -20
# git checkout <known-good-commit>

nix build .#nixosConfigurations.opi4pro.config.system.build.opi4proUboot --print-build-logs -o result-uboot
ls -l result-uboot/                    # boot0_sdcard.fex (tens of KB) and boot_package.fex (~1.4 MB)

lsblk                                  # CONFIRM the device
sudo dd if=result-uboot/boot0_sdcard.fex  of=/dev/sdX bs=1k seek=8     conv=notrunc,fsync
sudo dd if=result-uboot/boot_package.fex  of=/dev/sdX bs=1k seek=16400 conv=notrunc,fsync
sync
```

**Check it worked:** on serial you should see *your* banner — `U-Boot 2018.07-g<somehash>`, **without** `armbian` in the string —
then a **5-second** countdown, then `ret 0`, then `NOTICE: [SCP] …`, then `BL3-1: Next image address = 0x41000000`, then the
Linux banner.

> ### If you see `undefined instruction` right after `Starting kernel ...`
>
> Your U-Boot was built **without `-fomit-frame-pointer`**. This is by far the most likely way to brick this board from a config
> change, and the symptom looks nothing like the cause.
>
> Check that the `KCFLAGS=…-fomit-frame-pointer…` line is still present in `preBuild` in the U-Boot derivation.
> `cleanup_before_linux_select()` flushes the D-cache and then disables it, and is only safe because nothing is pushed onto the
> stack in between. Frame-pointer prologues push to the stack after the flush; those lines are dirty when the cache is disabled
> without writeback; the popped return address comes back as garbage and the CPU branches into nowhere.
>
> Ubuntu's `arm-linux-gnueabi-gcc` omits the frame pointer by default; every nixpkgs ARM cross-GCC keeps it. This flag must be
> supplied explicitly and must never be "cleaned up" away. Use §3a to get bootable again while you fix it.

### 3c. Reflash from the running board (no card removal)

If the board still boots — for example you changed the U-Boot derivation and the change has not taken effect — you do not need
the PC at all. `nixos-rebuild switch` never touches the raw sectors, so U-Boot changes require this tool:

```bash
sudo opi4pro-flash-uboot --check    # reports whether the card matches the current configuration
sudo opi4pro-flash-uboot            # writes both regions and verifies the readback
sudo reboot
```

This is safe on a live, mounted card: the bootloader region ends around 17.8 MiB and partition 1 starts at 48 MiB, so nothing
mounted is being written.

---

## 4. Inspect and repair the boot files (FAT partition)

Do this when U-Boot runs but cannot load or verify the kernel/initrd/DTB/boot script.

```bash
sudo mkdir -p /mnt/fw
sudo mount /dev/sdX1 /mnt/fw
ls -lR /mnt/fw
```

You must see all four (sizes approximate):

```
/mnt/fw/Image                                        ~25 MB   raw aarch64 kernel
/mnt/fw/uInitrd                                      ~38 MB   initrd wrapped in U-Boot's legacy format
/mnt/fw/allwinner/sun60i-a733-orangepi-4-pro.dtb     ~200 KB  device tree
/mnt/fw/boot.scr                                     ~1 KB    the compiled U-Boot boot script
```

If `boot.scr` is missing but the others are present, you are probably looking at a card built before `boot.scr` moved to the FAT
partition — check partition 2 for an old `/boot/boot.scr`, and see the bootable-flag note in §0.

If any file is missing, zero-length or truncated, §5 rewrites all four together.

```bash
sudo umount /mnt/fw
```

---

## 5. Roll the board back to a working generation (no rebuild)

This is the main recovery path. It works entirely from the board's own disks: every previous NixOS generation is still in
`/nix/store` **on the NVMe**. Pick one that worked and rewrite the four boot artifacts to point at it.

> This section rewrites the four files **in place** on the existing card, from a generation already on the NVMe — which is what
> you want for a rollback, and it needs no network and no rebuild. If instead the card itself is bad and you want a fresh one
> carrying the *current* system, §7 builds that in one command.

### 5a. Mount both disks and list the generations

You need the NVMe in your PC (an M.2 USB enclosure) **or** you can do this from the board itself if it still reaches a shell
(including the initrd emergency shell). The PC route:

```bash
lsblk -f                                   # find the NVMe (ext4, label NIXOS_ROOT) and the SD card
sudo mkdir -p /mnt/nixos /mnt/fw
sudo mount /dev/disk/by-label/NIXOS_ROOT /mnt/nixos     # the NVMe root
sudo mount /dev/sdX1 /mnt/fw                            # the SD card's FAT partition

ls -l /mnt/nixos/nix/var/nix/profiles/ | grep system
```

You will see something like:

```
system -> system-43-link
system-41-link -> /nix/store/aaaa…-nixos-system-opi4pro-…
system-42-link -> /nix/store/bbbb…-nixos-system-opi4pro-…
system-43-link -> /nix/store/cccc…-nixos-system-opi4pro-…
```

The highest number is the one that just broke. **Pick the one below it.**

```bash
GEN=42                                     # <-- change to the generation you want

TOPLEVEL_ON_DISK="$(readlink -f "/mnt/nixos/nix/var/nix/profiles/system-$GEN-link")"
echo "$TOPLEVEL_ON_DISK"                   # /mnt/nixos/nix/store/bbbb…-nixos-system-…

# The SAME path as the BOARD will see it (prefix stripped). This is what goes into the boot arguments.
TOPLEVEL_ON_BOARD="${TOPLEVEL_ON_DISK#/mnt/nixos}"
echo "$TOPLEVEL_ON_BOARD"                  # /nix/store/bbbb…-nixos-system-…

# Sanity check: all of these must exist
ls -l "$TOPLEVEL_ON_DISK/kernel" "$TOPLEVEL_ON_DISK/initrd" "$TOPLEVEL_ON_DISK/init" "$TOPLEVEL_ON_DISK/kernel-params"
ls -l "$TOPLEVEL_ON_DISK/dtbs/allwinner/sun60i-a733-orangepi-4-pro.dtb"
```

### 5b. Get `mkimage`

Needed to wrap the initrd and compile the boot script.

```bash
nix shell nixpkgs#ubootTools      # or: nix-shell -p ubootTools
mkimage -V                        # confirm it runs
```

### 5c. Rewrite the kernel, initrd and DTB on the FAT partition

```bash
sudo cp "$TOPLEVEL_ON_DISK/kernel" /mnt/fw/Image

sudo mkimage -A arm -O linux -T ramdisk -C gzip -n uInitrd \
  -d "$TOPLEVEL_ON_DISK/initrd" /mnt/fw/uInitrd

sudo mkdir -p /mnt/fw/allwinner
sudo cp "$TOPLEVEL_ON_DISK/dtbs/allwinner/sun60i-a733-orangepi-4-pro.dtb" \
  /mnt/fw/allwinner/sun60i-a733-orangepi-4-pro.dtb
```

Why the initrd is wrapped but the kernel is not: the boot script uses `booti`, which takes a **raw** aarch64 `Image`, but U-Boot
needs the legacy `uInitrd` wrapper to learn the ramdisk's size and compression. `-C gzip` must match the initrd's actual
compression (the configuration forces gzip for exactly this reason).

**Check:** `mkimage -l /mnt/fw/uInitrd` should print `Image Type: ARM Linux RAMDisk Image (gzip compressed)` and a sane size.

### 5d. Rewrite `boot.scr` (also on the FAT partition)

`boot.scr` is a *compiled* U-Boot script with the target generation's store path baked in, which is why it must be regenerated
whenever you change generations.

```bash
cat > /tmp/boot.cmd <<EOF
setenv kernel_addr_r 0x41000000
setenv fdt_addr_r 0x4a000000
setenv ramdisk_addr_r 0x4b000000
setenv fdt_high 0xffffffff
setenv initrd_high 0xffffffff
load mmc 0:1 \$ramdisk_addr_r uInitrd
load mmc 0:1 \$kernel_addr_r Image
load mmc 0:1 \$fdt_addr_r allwinner/sun60i-a733-orangepi-4-pro.dtb
fdt addr \$fdt_addr_r
fdt resize 65536
setenv bootargs "init=$TOPLEVEL_ON_BOARD/init $(cat "$TOPLEVEL_ON_DISK/kernel-params")"
booti \$kernel_addr_r \$ramdisk_addr_r \$fdt_addr_r
EOF

cat /tmp/boot.cmd                    # READ IT. init= must start with /nix/store, NOT /mnt/nixos.

sudo mkimage -C none -A arm -T script -d /tmp/boot.cmd /mnt/fw/boot.scr
```

Notes on the content, so you can reason about it years from now:

- **The memory addresses are load-bearing.** BL31 — the secure-monitor firmware — is *resident* at `0x48000000`–`0x48ffffff` and
  is still needed at the very last moment, because U-Boot calls into it via SMC to switch the CPU to 64-bit and enter the kernel.
  So the kernel loads *below* it and the DTB and initrd *above* it.
- **`fdt_high` / `initrd_high` = `0xffffffff` means "do not relocate".** Without them U-Boot moves the ~38 MB initrd to the top
  of its bootm pool, which lands on top of BL31 and destroys the monitor — the board then hangs silently right after
  `Starting kernel ...`.
- **Everything loads from `mmc 0:1`** — the FAT partition. Nothing is read from the SD's ext4 partition, and nothing on the SD is
  read from the NVMe at this stage; the kernel finds the NVMe root later, from the initrd.
- **There is deliberately no `root=` argument.** NixOS runs systemd inside the initrd and derives the root filesystem from the
  initrd's own fstab (which disko generated pointing at the NVMe). Passing `root=` as well makes it generate `sysroot.mount`
  twice and stage 1 aborts with *"Failed to create unit file … as it already exists"*.
- `kernel-params` is the file NixOS writes containing exactly the kernel parameters that generation was built with; reading it
  keeps this script consistent with the real configuration.

### 5e. Unmount and boot

```bash
sync
sudo umount /mnt/fw /mnt/nixos
```

Reassemble the board and power on with serial attached. **Check it worked**, in this order:

1. `U-Boot 2018.07-g…` banner, then a 5-second countdown
2. `Found U-Boot script` (from partition 1)
3. three successful `… bytes read` lines (initrd ≈ 38 MB, kernel ≈ 25 MB, DTB ≈ 200 KB)
4. `Starting kernel ...`
5. `NOTICE: [SCP] :arisc startup ready` and `NOTICE: BL3-1: Next image address = 0x41000000`
6. `[ 0.000000] Booting Linux on physical CPU …`
7. stage 1 mounts the NVMe root, then a login prompt

Once logged in, confirm you are on the generation you intended and that root really is on the SSD:

```bash
cat /proc/cmdline                    # the init= path must be the generation you chose
readlink -f /run/current-system
findmnt /                            # SOURCE must be /dev/nvme0n1p1
```

Then make it permanent, so the next `nixos-rebuild` builds on top of the working generation:

```bash
sudo nix-env -p /nix/var/nix/profiles/system --switch-generation 42
sudo /nix/var/nix/profiles/system/bin/switch-to-configuration switch
```

### 5f. If you can reach the U-Boot prompt, you can skip most of this

Booting an older generation by hand needs no card removal at all. Interrupt the 5-second countdown (any keypress; holding `s`
also works), then:

```
=> setenv kernel_addr_r 0x41000000
=> setenv fdt_addr_r 0x4a000000
=> setenv ramdisk_addr_r 0x4b000000
=> setenv fdt_high 0xffffffff
=> setenv initrd_high 0xffffffff
=> load mmc 0:1 ${ramdisk_addr_r} uInitrd
=> load mmc 0:1 ${kernel_addr_r} Image
=> load mmc 0:1 ${fdt_addr_r} allwinner/sun60i-a733-orangepi-4-pro.dtb
=> fdt addr ${fdt_addr_r}
=> fdt resize 65536
=> setenv bootargs "console=tty0 console=ttyS0,115200n8 earlyprintk=sunxi-uart,0x02500000 clk_ignore_unused init=/nix/var/nix/profiles/system/init"
=> booti ${kernel_addr_r} ${ramdisk_addr_r} ${fdt_addr_r}
```

`init=/nix/var/nix/profiles/system/init` boots whatever the current profile points at. For a specific older generation use
`init=/nix/var/nix/profiles/system-42-link/init`. Useful prompt commands: `ls mmc 0:1` (list the FAT partition),
`part list mmc 0 -bootable` (confirm partition 1 is the one being scanned), `printenv`.

If this boots, you have a running system — log in and run `sudo nixos-rebuild switch --rollback`, then reboot.

---

## 6. Reinstall from the installer image

Use this when the NVMe root is unrecoverable (filesystem corrupt, store damaged) but you want the standard system back. It wipes
the SSD and reinstalls from the flake.

⚠️ **This is not the way to replace a worn-out SD card.** It reinstalls onto the NVMe and wipes it. If the SSD is healthy and you
only need a new card, use **§7** instead, which preserves the SSD entirely.

**Prerequisite:** the target closure must be in the cache first, or the board will try to build the vendor kernel and U-Boot
locally (days).

```bash
# on the build machine
nix build .#nixosConfigurations.opi4pro.config.system.build.toplevel --no-link --print-out-paths \
  | xargs nix store sign --key-file ~/.config/nix/giggio.key --recursive
nix build .#nixosConfigurations.opi4pro.config.system.build.toplevel --no-link --print-out-paths \
  | xargs attic push servers

# build and burn the installer SD image
nix build .#opi4pro_img --print-build-logs
zstd -d -c result/opi4pro.img.zst | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

Put the card in the board, connect Ethernet, power on, watch serial. The installer will: wait for DNS and for NTP to set the
clock, zero and partition the NVMe with disko, bind-mount the SD's FAT partition into the target, run `nixos-install`, and
reboot into the installed system.

**Things that legitimately appear and are not failures:**

- `Cannot read ssh key … / cannot read keyfile '/etc/sops/age/server.agekey'` and `Activation script snippet 'setupSecrets'
  failed` — expected. The age key arrives on a USB stick at first boot.
- A `401 Unauthorized` from the private cache — the installer has no attic credentials; the bulk of the closure comes from
  `cache.nixos.org` and the board-specific parts are already in the installer's own store.

**If the installer aborts**, it restores the login prompts and autologs in as root on both consoles, so you can debug in place:
`journalctl -u unattended-install`, `ip a`, `resolvectl status`, `lsblk -f`.

---

## 7. Replace the SD card without reinstalling

This is the right path when the **card** is the problem — it is failing, it is too small, or you simply want a spare ready — and
the NVMe root is healthy. It reinstalls nothing and never touches the SSD.

`nix build .#opi4proboot_img` produces a **boot-only** card image: the raw bootloader region plus a single bootable FAT
partition holding the same four files a `nixos-rebuild switch` writes. It is ~304 MiB uncompressed (about 51 MiB compressed),
against several GB for the installer, and it fits a 4 GB card with room to spare.

> **The one coupling you must respect.** `boot.scr` bakes an absolute `init=/nix/store/<toplevel>/init`, so the card is tied to
> one specific system generation, and **that store path must already exist on the NVMe**. Build the card from the same flake
> revision the board is actually running. Deploy first, then build the card, then verify the two match before flashing.

```bash
# 1. Deploy the revision you are about to build the card from, so the NVMe has its closure.
#    (Skip only if the board is already running exactly this revision.)
nixos-rebuild switch --flake .#opi4pro --target-host <user>@<board> --use-remote-sudo

# 2. VERIFY. These two must print the SAME store path. If they differ, stop — the card will not boot.
nix eval --raw .#nixosConfigurations.opi4pro.config.system.build.toplevel
ssh <board> readlink -f /run/current-system

# 3. Build and flash.
nix build .#opi4proboot_img --print-build-logs
lsblk                                    # CONFIRM the device
zstdcat result/opi4proboot.img.zst | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

Or, with the Makefile: `make out/nix/img/opi4proboot.img.zst`.

### Verify the card before you trust it

The four files are generated so that a card and a running system are **byte-identical**, which makes this a real check rather
than an eyeball comparison. On the board:

```bash
sudo sha256sum /boot/firmware/{Image,uInitrd,boot.scr} /boot/firmware/allwinner/*.dtb
```

and on the PC, with the freshly flashed card's FAT partition mounted:

```bash
sha256sum /path/to/FIRMWARE/{Image,uInitrd,boot.scr} /path/to/FIRMWARE/allwinner/*.dtb
```

All four hashes must match. Two details make that possible, and both will bite you if they are ever undone:

- The `boot.scr` derivation strips its own explanatory comments before `mkimage` sees them, so it emits exactly what the
  switch-time install hook emits. (Before this, the card's `boot.scr` was 1872 bytes and the system's 788 — same commands,
  different bytes.)
- Both `mkimage` call sites pin `SOURCE_DATE_EPOCH`. The legacy U-Boot header stores a generation timestamp that also feeds the
  header CRC, so without pinning, a switch-generated `uInitrd`/`boot.scr` could never match a nix-built one even with an
  identical payload — the sizes match and 8 bytes differ.

### When this is *not* the right tool

- **The NVMe root is gone or corrupt** → §6, the installer, which wipes and reinstalls.
- **You need a generation that is on the NVMe but not in your flake** (a rollback) → §5, which rewrites the four files in place
  from whatever is already in `/nix/store`.
- **Only the bootloader is bad and the card is otherwise fine** → §3, cheaper.

### Keep a spare

The old card is a perfect backup of a known-good boot chain, so keep it rather than reusing it — if a new card misbehaves, put
the old one back and you are running again in a minute. Building a spare while the system is healthy costs one command, and it
is the cheapest insurance on this board given the card can never be removed.

---

## 8. Why source-only recovery works here, and its one limit

Everything in this project rebuilds from pinned sources: the Nix modules fix exact revisions and content hashes for the vendor
U-Boot, the vendor Linux kernel, Armbian's build repo and Orange Pi's build repo. Combined with the flake lock, any commit of
this repository reproduces the same bootloader and the same system, indefinitely. So the recovery of first resort is: **check out
a commit you know booted, rebuild, reflash.** You do not need a rescue distribution.

The one honest limit: three components of the boot chain are **binary blobs with no public source anywhere**:

| Blob | Role | Source |
|---|---|---|
| `boot0` | initializes the LPDDR5 DRAM; nothing runs before it | `armbian/build` (pinned) |
| `monitor.fex` (BL31) | ARM Trusted Firmware; performs the 32→64-bit kernel handoff | `orangepi-build` (pinned) |
| `scp.fex` | firmware for the power-management coprocessor | `orangepi-build` (pinned) |

Nobody — not Armbian, not Orange Pi — has source for these. "Building from source" on this SoC therefore means everything except
these three, which are instead *fetched reproducibly by pinned hash*.

**Practical consequence:** a source rebuild needs network access or a warm Nix store. For genuinely offline-capable recovery,
archive the outputs while the system is healthy:

```bash
nix build .#nixosConfigurations.opi4pro.config.system.build.opi4proUboot -o result-uboot
mkdir -p ~/opi4pro-recovery
cp -L result-uboot/boot0_sdcard.fex result-uboot/boot_package.fex ~/opi4pro-recovery/

# stronger: archive the whole closure so it can be restored into any Nix store offline
nix copy --to file://$HOME/opi4pro-recovery/nix-cache \
  .#nixosConfigurations.opi4pro.config.system.build.opi4proUboot
```

Those two `.fex` files are a few MB and are all §3 needs. The blobs committed in git (§3a) serve the same purpose and are already
in the repository — a convenience, not a dependency.

---

## 9. Things that look like faults but are not

Do not chase these; they appear in working boots.

| Message | Explanation |
|---|---|
| `boot param - magic error` | boot0 noise; appears in working Armbian boots too. |
| `error: dtb not found for scp`, `mmc not para` | boot0 noise. |
| `BL31: No DTB found.`, `ERROR: Error initializing runtime service opteed_fast` | BL31 noise; the monitor works regardless. |
| `MMC Device 2 not found` / `no mmc device at slot 2` | The SoC looking for eMMC, which this board does not have fitted. |
| `UFS init failed: -6` | The board has no UFS storage; the vendor tree probes for it anyway. |
| `Unrecognized filesystem type` when U-Boot looks for `boot.bmp` | The vendor splash-screen loader; harmless. |
| `axp8191-temp-ctrl: Failed to locate of_node`, `bmu_axp515_probe pmic_bus_read fail` | Absent PMIC sub-devices; patched out of the kernel DTS but still probed by U-Boot. |
| `supply hci not found, using dummy regulator` | Vendor USB driver noise. |
| `sunxi_usbc: get id is fail` / `usb detect mode isn't supported` | The USB-C OTG ID pin does not exist on this board. See §10. |
| `runtime_suspend disable clock` warnings from `sunxi_pd_test` | Vendor power-domain driver noise. |

---

## 10. USB notes

The single USB-A port's **USB-2 half** (controllers `ehci0`/`ohci0`, buses 5 and 6) is gated behind the sunxi OTG manager, which
cannot detect a port role because this board has no ID-pin GPIO. The device tree is patched to force host mode
(`usb_port_type = <0x1>`, `usb_detect_type = <0x0>` on `&usbc0` in the board DTS), and an initrd udev rule writes the same at
runtime.

**Symptom if that patch is ever lost:** USB-3 devices work, USB-2 devices are invisible, and `lsusb -t` shows only four buses
instead of six. Confirm and work around it live:

```bash
lsusb -t                                                             # want buses 5 (ehci) and 6 (ohci) present
cat /proc/device-tree/soc@3000000/usbc0@10/usb_port_type | xxd       # want 00000001, not 00000002
echo 1 | sudo tee /sys/devices/platform/soc@3000000/10.usbc0/otg_role # forces host mode immediately
```

The `otg_role` knob accepts `0` (device), `1` or `usb_host` (host), `2` (OTG). The words `host` and `device` are rejected.

---

## 11. Quick reference

| Fact | Value |
|---|---|
| Serial console | 115200 baud, 8N1 |
| U-Boot countdown | 5 seconds (any key aborts; holding `s` also drops to shell) |
| boot0 raw offset | 8 KiB (`dd … bs=1k seek=8`) |
| boot_package raw offset | 16400 KiB (`dd … bs=1k seek=16400`) |
| SD partition 1 (`FIRMWARE`) | vfat, starts 48 MiB, 256 MiB, **bootable**; holds `Image`, `uInitrd`, `allwinner/*.dtb`, `boot.scr` |
| SD partition 2 (`NIXOS_SD`) | ext4; leftover installer root, unused. Absent on a boot-only card |
| NVMe root | `/dev/nvme0n1p1`, ext4, label `NIXOS_ROOT`; holds `/nix/store` and all generations |
| Kernel load address | `0x41000000` (below BL31) |
| DTB load address | `0x4a000000` (above BL31) |
| Initrd load address | `0x4b000000` (above BL31) |
| BL31 (resident — never overwrite) | `0x48000000`–`0x48ffffff` |
| Must-have U-Boot flag | `-fomit-frame-pointer` in `KCFLAGS` — omitting it bricks the boot |
| Bootable flag must be on | partition 1 (`sudo sfdisk --activate /dev/sdX 1`) |
| Known-good bootloader in git | commit `641213b381e93917ee1c23fb0b2c1c05719170b7`, `modules/blobs/armbian-*.fex` |
| Armbian `boot_package.fex` size | 1392640 bytes |
| Generations | `/nix/var/nix/profiles/system-*-link` **on the NVMe** |
| Reflash bootloader from the board | `sudo opi4pro-flash-uboot` |
| Build bootloader only | `nix build .#nixosConfigurations.opi4pro.config.system.build.opi4proUboot` |
| Build installer image (wipes NVMe) | `nix build .#opi4pro_img` |
| Build boot-only card image (§7, safe) | `nix build .#opi4proboot_img` — ~304 MiB, fits a 4 GB card |
| Card must match the running generation | `nix eval --raw .#nixosConfigurations.opi4pro.config.system.build.toplevel` vs `readlink -f /run/current-system` |
| Card is verifiable by hash | the four FAT files are byte-identical to a running system's `/boot/firmware` |
| Deploy a change | sign closure `--recursive`, then `nixos-rebuild switch --flake .#opi4pro --target-host …` |
