# Disaster Recovery — Orange Pi 4 Pro (NixOS, Allwinner A733 / sun60iw2)

**Read this when the board no longer boots.** It assumes you have not touched this project in a long time and remember
nothing. It walks from "the board is dead" to "the board boots again", preferring the cheapest repair that will work.

> **If you read only one thing:** this board boots from the **SD card** and runs from the **NVMe SSD**. The SD card can
> never be removed — the SoC's boot ROM can only fetch the first-stage loader from SD raw sectors, never from PCIe.
> Almost every failure is repaired by rewriting something on the SD card, while the SSD (which holds every NixOS
> generation you have ever built) is left untouched.
>
> **To boot an older generation, pick it from the boot menu** on the serial console. See **§5a**.
>
> **If the card itself is dying, you do not need to reinstall.** With the board still running, build a card from its
> generations (`make boot_card_opi4pro BOARD=<ssh target>`), flash it to a new card, swap it in. It reproduces the whole
> boot chain and never touches the NVMe. See **§7**.

---

## 0. What you need before you start

- The board, with both its SD card and its NVMe SSD.
- A PC with an SD card reader (any Linux machine; `nix` is needed only for §3b, §5b and §7).
- A checkout of this NixOS configuration repository. It pins every source by hash, so it rebuilds identically years
  later.
- A **serial console** on the board's debug UART header at **115200 baud, 8N1**. This is not optional — until Linux is
  running there is no other output channel. On the PC: `sudo picocom -b 115200 /dev/ttyUSB0` (or
  `screen /dev/ttyUSB0 115200`).

> Serial troubleshooting, learned the hard way: if you get **nothing at all**, unplug and replug the USB-serial adapter
> before concluding the board is dead. A wedged adapter looks exactly like a wedged board. Also fully power-cycle the
> board (unplug, wait ~20 seconds, replug) — these Allwinner boards can latch into a state where the boot ROM does not
> re-run on a warm reset.

Throughout, `/dev/sdX` means the **whole SD card device** (e.g. `/dev/sdb`, or `/dev/mmcblk0` on a built-in reader).
**Confirm it with `lsblk` before every `dd`.** Writing to the wrong device destroys your PC's disk.

### The disk layout

**SD card** — the boot device. Two partitions, plus a bootloader region in raw sectors that no filesystem shows you:

| Where | Contents |
|---|---|
| raw offset **8 KiB** | `boot0_sdcard.fex` — Allwinner's DRAM-init blob, read directly by the SoC's boot ROM |
| raw offset **16400 KiB** | `boot_package.fex` — U-Boot + BL31 (secure monitor) + SCP firmware, read by boot0 |
| partition 1 — vfat, label `FIRMWARE`, starts at 48 MiB, **bootable flag set** | **`boot.scr`**, and the boot menu: `menu/extlinux.conf` plus the kernels, initrds and DTBs it loads, under `menu/nixos/`. 3 GiB on a boot-only card, 256 MiB on an installer card |
| partition 2 — ext4, label `NIXOS_SD` | Leftover installer root. **Not used by the running system.** Ignore it. *Absent entirely on a card written by the boot-only image (§7) — that is normal, not damage.* |

**NVMe SSD** — the root filesystem:

| Where | Contents |
|---|---|
| `/dev/nvme0n1p1` — ext4, label `NIXOS_ROOT`, partlabel `disk-main-nixos` | `/`, `/nix/store`, and **every NixOS generation** |

Two things about this layout are load-bearing and easy to break:

1. **Everything U-Boot reads lives on the FAT partition (partition 1), not on any ext4 root.** Older cards had `boot.scr`
   at `/boot/boot.scr` on partition 2. If you are looking at an old card, that is why.
2. **The bootable flag must be on partition 1.** U-Boot's distro-boot scan runs `part list mmc 0 -bootable` and only
   searches partitions in that list for `boot.scr`. If the flag is on partition 2 (the nixpkgs default), U-Boot will
   never find the boot script. Fix with `sudo sfdisk --activate /dev/sdX 1`.

---

## 1. First: work out *how far* the boot gets

Power the board with serial attached and read the output. Do not skip this — the fix depends entirely on where it stops.

| What you see on serial | What it means | Go to |
|---|---|---|
| **Nothing at all** | Replug the serial adapter; fully power-cycle the board (20 s unplugged). If still silent, see §2's checks — the raw bootloader may be missing. | **§2**, then **§3** |
| `HELLO! BOOT0 is starting!` then it stops or loops | The bootloader region is damaged or wrong. | **§3** |
| U-Boot banner (`U-Boot 2018.07-g…`) appears, then `undefined instruction`, or a hang right after `Starting kernel ...` | U-Boot itself is bad. | **§3** |
| U-Boot runs but cannot find `boot.scr`, shows no menu, or an entry fails with `Skipping … for failure retrieving` | Bootloader fine; the boot files or the bootable flag are wrong. | **§4**, then **§5b** |
| Kernel banner appears, then stage 1 fails: cannot find root, drops to an initrd emergency shell | Boot files fine; the NVMe root is unreachable or the generation is broken. | **§5a** |
| Boots, but the system is broken (services failing, bad config) | Roll back to a previous generation from the menu. | **§5a** |

**The key insight for this board:** `/nix/store` on the NVMe almost always survives, and it still contains
**every previous generation**, and the boot menu lists the newest of them. So recovery is nearly always "pick a
generation that worked" (§5), not "rebuild everything".

---

## 2. Confirm the bootloader is physically on the card

Do this when you get no output at all, or output that stops before U-Boot. It takes two minutes and tells you whether
the raw bootloader region is intact. Put the card in your PC:

```bash
lsblk                                   # identify the card, e.g. /dev/sdb

# boot0 must be at 8 KiB. A valid boot0 carries the "eGON.BT0" magic near its start.
sudo dd if=/dev/sdX bs=1k skip=8 count=1 2>/dev/null | xxd | head -4

# the boot package must be at 16400 KiB. It starts with the TOC1 name "sunxi-package".
sudo dd if=/dev/sdX bs=1k skip=16400 count=1 2>/dev/null | xxd | head -8

# the bootable flag must be on partition 1 (look for the "*" in the Boot column)
sudo sfdisk --list /dev/sdX
```

**Expected:** `eGON.BT0` in the first dump; `sunxi-package` followed by `u-boot` in the second; a `*` against
partition 1. A card written by the boot-only image (§7) shows **one** partition and nothing else; an installer-written
card shows two. Either is fine — what matters is that partition 1 carries the `*`.

- Missing magic, or all zeros → the bootloader is gone. Go to **§3**.
- Both present and the flag is on partition 1 → the bootloader is fine; your problem is later. Go to **§4** or **§5**.
- Both present but the flag is on partition **2** → that alone will prevent boot. Fix it:
  `sudo sfdisk --activate /dev/sdX 1`.

---

## 3. Repair the bootloader (raw sectors)

Do this when the board dies before or inside U-Boot: no U-Boot banner, `undefined instruction`, or a hang immediately
after `Starting kernel ...`.

Nothing here touches any filesystem — you are only rewriting raw sectors that live before partition 1.

There are three sources for a working bootloader. **§3c is easiest if the board still boots at all**;
**§3a is the fastest cold repair**; **§3b is the from-source path.**

### 3a. Restore the known-good bootloader stored in git

Two verified-bootable bootloader files were committed early in this project and later removed from the working tree.
They are still in git history, in commit **`641213b381e93917ee1c23fb0b2c1c05719170b7`**:

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

If you still have `toc1_extract.py` from this project, a stronger check — it must list exactly three items (`u-boot`,
`monitor`, `scp`):

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

`conv=notrunc` means "do not truncate the destination" — essential, or you would wipe the rest of the card. `seek=`
counts in `bs` units, so `bs=1k seek=16400` is byte offset 16400 × 1024.

**Check it worked:** boot with serial. You should see a U-Boot banner. This binary is Armbian's build, so it reads
`U-Boot 2018.07_armbian-…` and its countdown is ~1 second rather than 5 — expected and harmless. Your boot files are
untouched, so it will try to boot your system next; continue to §4/§5 if it still fails.

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

**Check it worked:** on serial you should see *your* banner — `U-Boot 2018.07-g<somehash>`, **without** `armbian` in the
string — then a **5-second** countdown, then `ret 0`, then `NOTICE: [SCP] …`, then
`BL3-1: Next image address = 0x41000000`, then the Linux banner.

> ### If you see `undefined instruction` right after `Starting kernel ...`
>
> Your U-Boot was built **without `-fomit-frame-pointer`**. This is by far the most likely way to brick this board from
> a config change, and the symptom looks nothing like the cause.
>
> Check that the `KCFLAGS=…-fomit-frame-pointer…` line is still present in `preBuild` in the U-Boot derivation.
> `cleanup_before_linux_select()` flushes the D-cache and then disables it, and is only safe because nothing is pushed
> onto the stack in between. Frame-pointer prologues push to the stack after the flush; those lines are dirty when the
> cache is disabled without writeback; the popped return address comes back as garbage and the CPU branches into
> nowhere.
>
> Ubuntu's `arm-linux-gnueabi-gcc` omits the frame pointer by default; every nixpkgs ARM cross-GCC keeps it. This flag
> must be supplied explicitly and must never be "cleaned up" away. Use §3a to get bootable again while you fix it.

### 3c. Reflash from the running board (no card removal)

If the board still boots — for example you changed the U-Boot derivation and the change has not taken effect — you do
not need the PC at all. `nixos-rebuild switch` never touches the raw sectors, so U-Boot changes require this tool:

```bash
sudo opi4pro-flash-uboot --check    # reports whether the card matches the current configuration
sudo opi4pro-flash-uboot            # writes both regions and verifies the readback
sudo reboot
```

This is safe on a live, mounted card: the bootloader region ends around 17.8 MiB and partition 1 starts at 48 MiB, so
nothing mounted is being written.

---

## 4. Inspect and repair the boot files (FAT partition)

Do this when U-Boot runs but shows no menu, or the menu cannot load an entry's kernel, initrd or DTB.

```bash
sudo mkdir -p /mnt/fw
sudo mount /dev/sdX1 /mnt/fw
ls -lR /mnt/fw
cat /mnt/fw/menu/extlinux.conf
```

You must see (sizes approximate):

```text
/mnt/fw/boot.scr                  ~300 B    static boot script: memory map, then `sysboot` on the menu
/mnt/fw/menu/extlinux.conf        a few KB  the menu, one LABEL per generation
/mnt/fw/menu/nixos/<hash>-Image   ~27 MB    kernels, one per distinct kernel
/mnt/fw/menu/nixos/<hash>-initrd  ~40 MB    initrds, raw (no uInitrd wrapper), one per distinct initrd
/mnt/fw/menu/nixos/<hash>-dtb     ~210 KB   device trees, one per distinct kernel
```

`<hash>` is the store hash of what the file was copied from. Every `LINUX`, `INITRD` and `FDT` line in `extlinux.conf`
names one of them by its absolute path. A file a line names that is missing, zero-length or truncated breaks that entry
only: U-Boot skips it and tries the next entry. §5c rewrites the whole partition from the PC.

Two things this U-Boot needs from the conf, both learned by booting it (2026-10-03):

- **No path over 127 characters**, conf directory included. `pxe.c` prints `Base path too long` and skips the entry.
  That is why the files have short names instead of the store names nixpkgs' extlinux builder would give them.
- **`TIMEOUT 1200000`, not `50`.** This U-Boot's menu counts its timeout in units 24000 times too short, so `50` boots
  the default instantly. `1200000` is 5 seconds here. See `menuTimeout` in `modules/opi4pro-boot-files.nix`.

**A card from before the boot menu** has `Image`, `uInitrd`, `allwinner/…dtb` and a larger `boot.scr` at the root of the
partition instead, and no `menu/`. That layout still boots, one generation only; the first `nixos-rebuild switch` of a
configuration with the menu replaces it.

```bash
sudo umount /mnt/fw
```

---

## 5. Roll the board back to a working generation (no rebuild)

This is the main recovery path. Every previous NixOS generation is still in `/nix/store` **on the NVMe**, and the boot
menu on the card lists the newest of them (the current system plus up to 20 older ones). Pick one that worked.

### 5a. Pick an older generation from the boot menu

No card removal, no PC. Power on with serial attached. After U-Boot's 5-second countdown (do not press anything there),
the menu appears:

```text
------------------------------------------------------------
1:  NixOS - Default
2:  NixOS - Configuration 48-default (2026-10-01 01:23 - 26.05.20260927.cf5e765)
3:  NixOS - Configuration 47-default (2026-09-30 12:44 - 26.05.20260927.cf5e765)
…
Enter choice:
```

Type the number in front of the entry and Enter, within 5 seconds. That number is the entry's position in the list,
not the generation: for generation 46 above it is `4`, and typing `46` only gets `46 not found` and the menu again. Any
keypress stops the countdown, so you can read the list first; after that the menu waits for a choice. With no input it
boots `Default`, which is the newest generation. Ctrl-C leaves the menu for the `=>` prompt.

Once logged in, confirm you are on the generation you picked:

```bash
cat /proc/cmdline                    # the init= path must be the generation you chose
readlink -f /run/booted-system
findmnt /                            # SOURCE must be /dev/nvme0n1p1
```

The menu choice lasts one boot. To make it the default, so the next `nixos-rebuild` builds on top of it:

```bash
sudo nix-env -p /nix/var/nix/profiles/system --switch-generation 42    # the number you picked
sudo /nix/var/nix/profiles/system/bin/switch-to-configuration switch
```

That runs the bootloader hook too, so the menu's `Default` becomes that generation.

### 5b. If the menu does not come up, but the U-Boot prompt does

Interrupt the 5-second countdown (any keypress; holding `s` also works) and run what `boot.scr` runs:

```text
=> setenv kernel_addr_r 0x41000000
=> setenv fdt_addr_r 0x4a000000
=> setenv pxefile_addr_r 0x4a800000
=> setenv ramdisk_addr_r 0x4b000000
=> setenv fdt_high 0xffffffff
=> setenv initrd_high 0xffffffff
=> sysboot mmc 0:1 any ${pxefile_addr_r} /menu/extlinux.conf
```

If `sysboot` cannot read the menu, boot one entry by hand after the same six `setenv` lines. `ls mmc 0:1 /menu/nixos`
lists the files; load the initrd **last**, because `booti` needs its size, and `${filesize}` holds whatever was loaded
most recently:

```text
=> load mmc 0:1 ${kernel_addr_r} /menu/nixos/<hash>-Image
=> load mmc 0:1 ${fdt_addr_r} /menu/nixos/<hash>-dtb
=> load mmc 0:1 ${ramdisk_addr_r} /menu/nixos/<other hash>-initrd
=> setenv bootargs "console=tty0 console=ttyS0,115200n8 earlyprintk=sunxi-uart,0x02500000 clk_ignore_unused init=/nix/var/nix/profiles/system-42-link/init"
=> booti ${kernel_addr_r} ${ramdisk_addr_r}:${filesize} ${fdt_addr_r}
```

`init=/nix/var/nix/profiles/system/init` boots whatever the current profile points at; `system-42-link` a specific
generation. Any kernel and initrd on the card will do as long as they are recent enough for that generation's modules.
Useful prompt commands: `ls mmc 0:1 /menu/nixos`, `part list mmc 0 -bootable` (confirms partition 1 is the one being
scanned), `printenv`.

If this boots, you have a running system — log in and run `sudo nixos-rebuild switch --rollback`, or §5a's two commands,
then reboot.

Notes on the memory map, so you can reason about it years from now:

- **The addresses are load-bearing.** BL31 — the secure-monitor firmware — is *resident* at `0x48000000`–`0x48ffffff`
  and is still needed at the very last moment, because U-Boot calls into it via SMC to switch the CPU to 64-bit and
  enter the kernel. So the kernel loads *below* it and the DTB, the menu file and the initrd *above* it.
- **`fdt_high` / `initrd_high` = `0xffffffff` means "do not relocate".** Without them U-Boot moves the ~40 MB initrd to
  the top of its bootm pool, which lands on top of BL31 and destroys the monitor — the board then hangs silently right
  after `Starting kernel ...`. This is also why the menu is not at `/extlinux/extlinux.conf`: distro boot would find it
  there before `boot.scr` and boot it without these settings.
- **Everything loads from `mmc 0:1`** — the FAT partition. The kernel finds the NVMe root later, from the initrd.
- **There is deliberately no `root=` argument.** NixOS runs systemd inside the initrd and derives the root filesystem
  from the initrd's own fstab (which disko generated pointing at the NVMe). Passing `root=` as well makes it generate
  `sysroot.mount` twice and stage 1 aborts with *"Failed to create unit file … as it already exists"*.

### 5c. Rewrite the card from the PC

When neither the menu nor the prompt gets you anywhere, and the card is fine but its FAT partition is not. This works
from the disks alone: the NVMe in an M.2 USB enclosure, the SD card in the reader. (If the **card** is the problem
rather than its files, §7 is quicker: it builds a new one.)

```bash
lsblk -f                                   # find the NVMe (ext4, label NIXOS_ROOT) and the SD card
sudo mkdir -p /mnt/nixos /mnt/fw
sudo mount /dev/disk/by-label/NIXOS_ROOT /mnt/nixos     # the NVMe root
sudo mount /dev/sdX1 /mnt/fw                            # the SD card's FAT partition

ls -l /mnt/nixos/nix/var/nix/profiles/ | grep system
```

You will see something like:

```text
system -> system-43-link
system-41-link -> /nix/store/aaaa…-nixos-system-opi4pro-…
system-42-link -> /nix/store/bbbb…-nixos-system-opi4pro-…
system-43-link -> /nix/store/cccc…-nixos-system-opi4pro-…
```

The highest number is the newest. **Pick one you know booted.** The links are absolute `/nix/store` paths that mean the
board's store, so resolve them by hand under `/mnt/nixos`:

```bash
GEN=42                                     # <-- change to the generation you want

TOPLEVEL_ON_BOARD="$(readlink "/mnt/nixos/nix/var/nix/profiles/system-$GEN-link")"
TOPLEVEL_ON_DISK="/mnt/nixos$TOPLEVEL_ON_BOARD"
echo "$TOPLEVEL_ON_BOARD"                  # /nix/store/bbbb…-nixos-system-…   (goes into init=)
KERNEL="/mnt/nixos$(readlink "$TOPLEVEL_ON_DISK/kernel")"
INITRD="/mnt/nixos$(readlink "$TOPLEVEL_ON_DISK/initrd")"
DTB="/mnt/nixos$(readlink "$TOPLEVEL_ON_DISK/dtbs")/allwinner/sun60i-a733-orangepi-4-pro.dtb"
ls -l "$KERNEL" "$INITRD" "$DTB" "$TOPLEVEL_ON_DISK/init" "$TOPLEVEL_ON_DISK/kernel-params"   # all must exist
```

Write a one-entry menu and the static `boot.scr`. The menu's file names are free; these are short on purpose:

```bash
sudo mkdir -p /mnt/fw/menu/nixos
sudo cp "$KERNEL" /mnt/fw/menu/nixos/rescue-Image
sudo cp "$INITRD" /mnt/fw/menu/nixos/rescue-initrd
sudo cp "$DTB"    /mnt/fw/menu/nixos/rescue.dtb

sudo tee /mnt/fw/menu/extlinux.conf > /dev/null <<EOF
DEFAULT rescue
TIMEOUT 1200000
MENU TITLE ------------------------------------------------------------

LABEL rescue
  MENU LABEL NixOS - Configuration $GEN (written by hand)
  LINUX /menu/nixos/rescue-Image
  INITRD /menu/nixos/rescue-initrd
  APPEND init=$TOPLEVEL_ON_BOARD/init $(cat "$TOPLEVEL_ON_DISK/kernel-params")
  FDT /menu/nixos/rescue.dtb
EOF
cat /mnt/fw/menu/extlinux.conf   # READ IT. init= must start with /nix/store, NOT /mnt/nixos.
```

`boot.scr` is the same on every card, so build it rather than write it:

```bash
cd /path/to/your/nixos-config
nix build .#nixosConfigurations.opi4pro.config.system.build.opi4proBootFiles.bootScript -o result-bootscr
sudo cp result-bootscr /mnt/fw/boot.scr
```

Without a checkout, compile the seven lines of §5b (the six `setenv` and the `sysboot`) with
`nix shell nixpkgs#ubootTools -c mkimage -C none -A arm -T script -d boot.cmd boot.scr` instead; in a file, the
`${pxefile_addr_r}` stays literal for U-Boot to expand.

```bash
sync
sudo umount /mnt/fw /mnt/nixos
```

Reassemble the board and power on with serial attached. **Check it worked**, in this order:

1. `U-Boot 2018.07-g…` banner, then a 5-second countdown
2. `Found U-Boot script` (from partition 1)
3. the menu, then `Retrieving file:` lines for the kernel, initrd and DTB
4. `Starting kernel ...`
5. `NOTICE: [SCP] :arisc startup ready` and `NOTICE: BL3-1: Next image address = 0x41000000`
6. `[ 0.000000] Booting Linux on physical CPU …`
7. stage 1 mounts the NVMe root, then a login prompt

Then confirm and make it permanent with §5a's commands. The switch rewrites the menu properly, with every generation.

---

## 6. Reinstall from the installer image

Use this when the NVMe root is unrecoverable (filesystem corrupt, store damaged) but you want the standard system back.
It wipes the SSD and reinstalls from the flake.

⚠️ **This is not the way to replace a worn-out SD card.** It reinstalls onto the NVMe and wipes it. If the SSD is
healthy and you only need a new card, use **§7** instead, which preserves the SSD entirely.

**Prerequisite:** the target closure must be in the cache first, or the board will try to build the vendor kernel and
U-Boot locally (days).

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

Put the card in the board, connect Ethernet, power on, watch serial. The installer will: wait for DNS and for NTP to set
the clock, zero and partition the NVMe with disko, bind-mount the SD's FAT partition into the target, run
`nixos-install`, and reboot into the installed system.

**Things that legitimately appear and are not failures:**

- `Cannot read ssh key … / cannot read keyfile '/etc/sops/age/server.agekey'` and
  `Activation script snippet 'setupSecrets' failed` — expected. The age key arrives on a USB stick at first boot.
- A `401 Unauthorized` from the private cache — the installer has no attic credentials; the bulk of the closure comes
  from `cache.nixos.org` and the board-specific parts are already in the installer's own store.

**If the installer aborts**, it restores the login prompts and autologs in as root on both consoles, so you can debug in
place: `journalctl -u unattended-install`, `ip a`, `resolvectl status`, `lsblk -f`.

---

## 7. Replace the SD card without reinstalling

This is the right path when the **card** is the problem — it is failing (cards here last about two years), or you
simply want a spare ready — and the NVMe root is healthy. It reinstalls nothing and never touches the SSD.

A **boot-only** card is the raw bootloader region plus one bootable FAT partition of 3 GiB holding `boot.scr` and the
boot menu. The image is ~3.05 GiB uncompressed, roughly 50–150 MiB compressed, and fits any 4 GB card. There are two
ways to fill its menu.

### 7a. From the running board (the normal way)

`opi4pro-boot-card` reads the board's generations over ssh and builds the card with the menu the board's own
`nixos-rebuild switch` would write: the current system plus up to 20 older generations. It is read-only on the board —
no sudo, nothing written there — and every entry is on the NVMe by construction, because that is where it was read
from.

```bash
cd /path/to/your/nixos-config
make boot_card_opi4pro BOARD=<ssh target>     # prints the menu it wrote, and the image path
lsblk                                         # CONFIRM the device
zstdcat out/nix/img/opi4proboot-card-<date>.img.zst | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

The script checks every file it copied against its sha256 on the board, and reads the whole partition back before it
compresses the image. To check what landed on the card, compare its first 3120 MiB (48 MiB of bootloader region plus the
3072 MiB partition, the whole image) with the image:

```bash
zstdcat out/nix/img/opi4proboot-card-<date>.img.zst | sudo cmp -n $((3120 * 1024 * 1024)) - /dev/sdX && echo "card matches the image"
```

### 7b. From the flake alone (the board is down)

`nix build .#opi4proboot_img` builds a card whose menu has **one** entry: the system of the revision you build from.

> **The one coupling you must respect.** That entry boots `init=/nix/store/<toplevel>/init`, so **that store path must
> already exist on the NVMe**. Build the card from the revision the board was last running, and check before flashing.

```bash
# These two must print the SAME store path. If they differ, stop — the entry will not boot.
nix eval --raw .#nixosConfigurations.opi4pro.config.system.build.toplevel
ssh <board> readlink -f /run/current-system        # or, with the board down, the NVMe mounted on the PC:
readlink /mnt/nixos/nix/var/nix/profiles/system-<N>-link

make out/nix/img/opi4proboot.img.zst               # or: nix build .#opi4proboot_img
lsblk                                              # CONFIRM the device
zstdcat out/nix/img/opi4proboot.img.zst | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

The first `nixos-rebuild switch` on the board fills the menu with every generation.

### When this is *not* the right tool

- **The NVMe root is gone or corrupt** → §6, the installer, which wipes and reinstalls.
- **You need a generation that is on the NVMe but not in the menu** → §5b boots it from the prompt, §5c writes it to the
  card by hand.
- **Only the bootloader is bad and the card is otherwise fine** → §3, cheaper.

### Keep a spare

The old card is a backup of a known-good boot chain, so keep it rather than reusing it — if a new card misbehaves, put
the old one back and you are running again in a minute. Its menu ages, though: it lists the generations of the day it
was last in the board, and those stay bootable only until a garbage collection removes them from the NVMe. Rebuild the
spare with §7a now and then.

---

## 8. Why source-only recovery works here, and its one limit

Everything in this project rebuilds from pinned sources: the Nix modules fix exact revisions and content hashes for the
vendor U-Boot, the vendor Linux kernel, Armbian's build repo and Orange Pi's build repo. Combined with the flake lock,
any commit of this repository reproduces the same bootloader and the same system, indefinitely. So the recovery of first
resort is: **check out a commit you know booted, rebuild, reflash.** You do not need a rescue distribution.

The one honest limit: three components of the boot chain are **binary blobs with no public source anywhere**:

| Blob | Role | Source |
|---|---|---|
| `boot0` | initializes the LPDDR5 DRAM; nothing runs before it | `armbian/build` (pinned) |
| `monitor.fex` (BL31) | ARM Trusted Firmware; performs the 32→64-bit kernel handoff | `orangepi-build` (pinned) |
| `scp.fex` | firmware for the power-management coprocessor | `orangepi-build` (pinned) |

Nobody — not Armbian, not Orange Pi — has source for these. "Building from source" on this SoC therefore means
everything except these three, which are instead *fetched reproducibly by pinned hash*.

**Practical consequence:** a source rebuild needs network access or a warm Nix store. For genuinely offline-capable
recovery, archive the outputs while the system is healthy:

```bash
nix build .#nixosConfigurations.opi4pro.config.system.build.opi4proUboot -o result-uboot
mkdir -p ~/opi4pro-recovery
cp -L result-uboot/boot0_sdcard.fex result-uboot/boot_package.fex ~/opi4pro-recovery/

# stronger: archive the whole closure so it can be restored into any Nix store offline
nix copy --to file://$HOME/opi4pro-recovery/nix-cache \
  .#nixosConfigurations.opi4pro.config.system.build.opi4proUboot
```

Those two `.fex` files are a few MB and are all §3 needs. The blobs committed in git (§3a) serve the same purpose and
are already in the repository — a convenience, not a dependency.

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

The single USB-A port's **USB-2 half** (controllers `ehci0`/`ohci0`, buses 5 and 6) is gated behind the sunxi OTG
manager, which cannot detect a port role because this board has no ID-pin GPIO. The device tree is patched to force host
mode (`usb_port_type = <0x1>`, `usb_detect_type = <0x0>` on `&usbc0` in the board DTS), and an initrd udev rule writes
the same at runtime.

**Symptom if that patch is ever lost:** USB-3 devices work, USB-2 devices are invisible, and `lsusb -t` shows only four
buses instead of six. Confirm and work around it live:

```bash
lsusb -t                                                             # want buses 5 (ehci) and 6 (ohci) present
cat /proc/device-tree/soc@3000000/usbc0@10/usb_port_type | xxd       # want 00000001, not 00000002
echo 1 | sudo tee /sys/devices/platform/soc@3000000/10.usbc0/otg_role # forces host mode immediately
```

The `otg_role` knob accepts `0` (device), `1` or `usb_host` (host), `2` (OTG). The words `host` and `device` are
rejected.

---

## 11. Quick reference

| Fact | Value |
|---|---|
| Serial console | 115200 baud, 8N1 |
| U-Boot countdown | 5 seconds (any key aborts; holding `s` also drops to shell) |
| Boot menu | after the countdown, 5 seconds; type the entry number and Enter. Default = newest generation, then up to 20 older |
| boot0 raw offset | 8 KiB (`dd … bs=1k seek=8`) |
| boot_package raw offset | 16400 KiB (`dd … bs=1k seek=16400`) |
| SD partition 1 (`FIRMWARE`) | vfat, starts 48 MiB, 3 GiB (256 MiB on an installer card), **bootable**; holds `boot.scr` and `menu/` |
| The menu | `menu/extlinux.conf`; deliberately not `/extlinux/`, which distro boot would boot without `boot.scr`. Paths in it at most 127 characters; `TIMEOUT 1200000` is 5 seconds on this U-Boot |
| SD partition 2 (`NIXOS_SD`) | ext4; leftover installer root, unused. Absent on a boot-only card |
| NVMe root | `/dev/nvme0n1p1`, ext4, label `NIXOS_ROOT`; holds `/nix/store` and all generations |
| Kernel load address | `0x41000000` (below BL31) |
| DTB load address | `0x4a000000` (above BL31) |
| Menu file load address | `0x4a800000` (`pxefile_addr_r`, above BL31) |
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
| Build a boot-only card from the running board (§7a, safe) | `make boot_card_opi4pro BOARD=<ssh target>` — 3.05 GiB image, fits a 4 GB card |
| Build a boot-only card from the flake (§7b, safe) | `nix build .#opi4proboot_img` — one entry, which must already be on the NVMe |
| Card is verifiable | `zstdcat <image> \| sudo cmp -n $((3120 * 1024 * 1024)) - /dev/sdX` |
| Deploy a change | sign closure `--recursive`, then `nixos-rebuild switch --flake .#opi4pro --target-host …` |
