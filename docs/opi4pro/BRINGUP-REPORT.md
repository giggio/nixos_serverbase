# Bringing NixOS Up on the Orange Pi 4 Pro (Allwinner A733): Full Technical Report

*Fourth revision (October 2026). The board boots NixOS from a self-built SD image, installs itself unattended onto an
NVMe SSD, runs with U-Boot, the Linux kernel, the initrd and the boot script all compiled from source, and boots through
a U-Boot menu of its NixOS generations. Three binary blobs remain (boot0, BL31, SCP firmware); none has public source
anywhere.*

---

## 1. Executive summary

The goal was to run NixOS on an Orange Pi 4 Pro — a single-board computer built around the Allwinner A733, a
system-on-chip (SoC: one piece of silicon integrating CPU cores, memory controller and peripherals) internally codenamed
sun60iw2 — and to do it the way every other machine in this fleet is done: declaratively, from pinned sources, installed
unattended, deployable with `nixos-rebuild switch`.

That turned out to require three distinct projects, each of which is documented below:

**Part A — the boot chain (§4).** This SoC has no mainline Linux and no mainline U-Boot support. The only working
software stack is Allwinner's vendor board support package (BSP), which Armbian repackages. Reproducing that boot chain
inside Nix surfaced seven separate failures, each masking the next: a disk-layout collision that silently corrupted the
kernel; a misunderstanding of how a 32-bit bootloader starts a 64-bit kernel on this chip; an initrd relocated on top of
the resident secure-monitor firmware; an init-system conflict from declaring the root filesystem twice; and finally, in
the from-source U-Boot, **frame pointers**, which corrupt U-Boot's cache-teardown path. One flag —
`-fomit-frame-pointer` — was the difference between a board that booted and a board that died with
`undefined instruction` at a nonsense address.

**Part B — the unattended installer (§5).** The SoC's boot ROM cannot read PCIe, so the SD card is a permanent boot
requirement and USB boot does not exist. The result is a hybrid: an SD card that boots an installer, which wipes an NVMe
SSD with disko, installs the real system onto it from the flake, and hands the boot chain over — after which the SD card
holds only boot artifacts and the SSD holds everything else. Bringing that up surfaced six more failures, all of them in
the gap between "a minimal installer environment" and "a real configured server": a missing `getent`, DNS that resolved
on every other machine but not here, a clock with no battery behind it, and a disko behaviour that silently skips
formatting.

**Part C — USB-2 host mode (§6).** The board's USB-2 host controllers never came up, because the OTG manager waits for
an ID pin that this board does not have. Two device-tree properties fixed it.

The system now runs from NVMe, is deployed over the network from a build machine, and recovers from a documented runbook
([`DISASTER-RECOVERY.md`](./DISASTER-RECOVERY.md)).

**Part D — replacing the SD card (§7), added after the original bring-up.** Because the card is a permanent part of
the boot chain, a worn-out or undersized card was initially a reinstall. It is not: the card holds only a bootloader
region and one FAT partition, so a **boot-only card** reproduces it without touching the NVMe. Since Part E it is built
from the running board's own generations, read over ssh.

**Part E — a boot menu of generations (§7, *The boot menu*), added in October 2026.** Until then the board booted one
generation, and rolling back meant mounting both disks on a PC. The vendor U-Boot turned out to have extlinux menu
support built in, behind three traps of its own: no memory map in its default environment, a 127-character limit on
every path in the menu, and a menu timeout that runs 24000 times too fast. Each one failed a real boot before it was
understood.

---

## 2. The hardware, and why this was hard

The A733 is a 2025-era Allwinner chip: eight 64-bit ARM cores (six Cortex-A55 efficiency cores and two Cortex-A76
performance cores — visible in the boot log as CPU part IDs `0x412fd050` and `0x414fd0b1`), LPDDR5 memory, and a boot
architecture Allwinner has never publicly documented. There is no mainline support, no upstream device tree, and no
open-source implementation of the early boot firmware. Everything known about booting it comes from two Git
repositories: `orangepi-xunlong/orangepi-build` (the manufacturer's build system, containing precompiled firmware
binaries and packing tools) and `armbian/build`, which received hardware-tested Orange Pi 4 Pro support in 2026 via pull
request armbian/build#9967.

Board peripherals relevant to this report: one microSD slot (the only bootable medium), one M.2 slot (`/dev/nvme0n1`),
one USB-A port, one USB-C port, gigabit Ethernet, HDMI, and a serial debug header.

All early debugging happened over that serial console (a UART — Universal Asynchronous Receiver-Transmitter — at 115200
baud), because until the kernel is running there is no other output channel.

---

## 3. How this SoC boots

Every stage below runs before a single line of Linux executes.

**Stage 0 — BROM (Boot ROM).** A small program burned into the silicon at manufacture. On power-on the CPU executes it.
It reads a few kilobytes from a fixed location on storage (SD card offset 8 KiB) and jumps to what it finds. It cannot
be changed, and it has **no PCIe/NVMe support** — which is why the SD card can never be removed from this board.

**Stage 1 — boot0.** Allwinner's proprietary first-stage loader, loaded by the BROM from SD offset 8 KiB. Its main job
is DRAM initialization: training the LPDDR5 memory (the `DRAM Training` lines, ~5 seconds). Until boot0 runs, the system
has no usable RAM. It is distributed only as a binary (`boot0_sdcard*.fex`). It then loads the next stage from SD offset
16400 KiB.

**Stage 2 — the boot package.** A container file (`boot_package.fex`) in Allwinner's "TOC1" format — a table-of-contents
header followed by named items. For this board it holds three: `monitor` (BL31), `scp`, and `u-boot`. boot0 loads each
item to its designated RAM address and jumps into BL31.

**BL31 / the monitor.** BL31 is stage 3-1 of ARM Trusted Firmware (TF-A), the reference secure-world firmware for 64-bit
ARM. It runs at EL3 — Exception Level 3, the highest privilege level the CPU has, above both the OS (EL1) and
hypervisors (EL2). Critically, BL31 does not run once and exit: it installs itself **permanently** in RAM at
`0x48000000`–`0x48ffffff` and stays resident for the life of the system, servicing privileged requests. Allwinner's BL31
for this chip is a blob (`monitor.fex`).

**SCP (System Control Processor).** A small auxiliary core (Allwinner calls it "arisc") handling power management. Its
firmware (`scp.fex`) is also a blob. BL31 starts it on request — the `[SCP] :arisc startup ready` lines in a successful
boot.

**Stage 4 — U-Boot.** The familiar open-source bootloader — except this is Allwinner's fork of U-Boot 2018.05, heavily
modified, and built as a **32-bit ARM program** even though the CPU and kernel are 64-bit. This is deliberate vendor
practice on recent Allwinner chips. U-Boot scans for a boot script, which sets the memory map and shows the menu of
generations (§7); it loads the chosen entry's kernel, initial ramdisk and device tree into RAM, and then hands over.

**The 32→64-bit handoff.** A 32-bit program cannot jump into 64-bit code; the CPU must change execution state, and only
EL3 can arrange that. So vendor U-Boot performs an SMC — a Secure Monitor Call, the ARM instruction that traps into EL3
— using Allwinner's private function `ARM_SVC_RUNNSOS` ("run non-secure OS"), passing the kernel entry point and the
device tree address. The still-resident BL31 receives the call, reconfigures the CPU to enter AArch64 state at the
kernel's address, and performs the switch. The log line `BL3-1: Next image address = 0x41000000` is BL31 announcing
exactly this. U-Boot decides whether to take this path by reading a byte called `monitor_exist` in its own image header,
which the proprietary packing tools stamp in at build time.

**Stage 5 — Linux.** The AArch64 kernel starts, with the device tree in hand.

Two data formats recur. A **DTB (Device Tree Blob)** is the compiled form of a device tree — a data structure describing
the hardware (what peripherals exist, at which addresses, on which interrupts) that ARM kernels require because ARM
boards, unlike PCs, are not self-describing. **FDT (Flattened Device Tree)** is the same thing viewed as an in-memory
format; U-Boot's `fdt` commands manipulate it. The `.fex` extension is just Allwinner's convention for firmware-pipeline
files.

---

## 4. Part A — the boot chain

### Phase 1 — "Bad Data CRC": the bootloader was overwriting the kernel

The first failure was U-Boot refusing the kernel with `Verifying Checksum ... Bad Data CRC`. The byte count was right;
the bytes were wrong.

The cause was arithmetic. The configuration wrote `boot_package.fex` to the raw card at offset 16400 KiB (≈16.4 MiB) —
the fixed location boot0 reads from — while the NixOS `sd-image` module had created the FAT firmware partition (holding
the kernel) at its default offset of 8 MiB, spanning 8–264 MiB. The `dd` landed *inside* the filesystem, silently
corrupting whatever file data lived there. Fixed with `sdImage.firmwarePartitionOffset = 48;` (48 MiB), which puts the
filesystem clear of the ~17.8 MiB the bootloader region ends at.

### Phase 2 — the architecture-tag dead end

Boot then reached the handoff and died with `undefined instruction`. Tagging the kernel image `-A arm` made U-Boot jump
directly into 64-bit machine code while in 32-bit state. Tagging it `-A arm64` hit `Unsupported Architecture 0x16`,
because this U-Boot's legacy-image path hard-rejects 64-bit payloads. The escape was `booti`, U-Boot's command for
booting a **raw** AArch64 `Image` with no wrapper and no architecture check — which the vendor's SMC handoff then
handles correctly. The lesson, from reading `arch/arm/lib/bootm.c`: this U-Boot never enters the kernel itself. It
always defers to BL31.

### Phase 3 — the `monitor_exist` expedition

Suspicion fell on that `monitor_exist` byte. By compiling the vendor's own header definitions into a small
offset-calculating program, its location was computed as byte `0x4e9` from U-Boot's load base `0x4a000000`. A live
memory dump at the U-Boot prompt (`md.b 0x4a0004e0 20`) showed `monitor_exist = 01`: the flag was fine, the SMC path was
being taken, and packing had never been the problem. Two changes made during this phase were later recognized as errors
and reverted — adding a second `update_uboot` stamping pass (Armbian stamps once), and switching from the board-specific
`boot0`/`sys_config` blobs to generic "a733 devkit" ones (Armbian's board file explicitly requires per-board blobs; DRAM
timing and pin configuration differ).

A useful side effect: raising `CONFIG_BOOTDELAY` made the `=>` prompt reachable, enabling every live diagnostic that
followed — though as Phase 8 shows, that change did not actually take effect until much later.

### Phase 4 — the initrd was being relocated on top of BL31

U-Boot maintains a "bootm pool" (governed by `bootm_size`, here `0xa000000` = 160 MiB, so the pool spans `0x40000000`–
`0x4a000000`) and by default **relocates** the initial ramdisk to the top of it before booting. The NixOS initrd is ~38
MiB, so relocation placed it at roughly `0x479db000`–`0x49fff2b5` — directly across BL31 at `0x48000000`. The resident
monitor was destroyed seconds before the SMC that needed it, producing a silent hang right after `Starting kernel ...`.
Armbian escapes purely by luck of size: its ~12.7 MiB initrd relocates clear of BL31's end.

The fix: `fdt_high=0xffffffff` and `initrd_high=0xffffffff`, U-Boot's "do not relocate, use in place" directives, plus
adopting Armbian's memory map — kernel *below* BL31 at `0x41000000`; FDT at `0x4a000000` and initrd at `0x4b000000`,
both *above* it.

### Phase 5 — Armbian as ground truth, and the transplant bisect

Armbian demonstrably boots this board, so its recipe became the reference: same U-Boot commit, same defconfig
(`sun60iw2p1_t736_defconfig`), same packing tools, no U-Boot patches. Their boot prologue also proved that the alarming
`boot param - magic error`, `error: dtb not found for scp`, `BL31: No DTB found.`, and
`Error initializing runtime service opteed_fast` messages **all appear in working boots** and are noise.

A known-good Armbian image was flashed to a spare card and verified to boot. Its two bootloader files were extracted
from the rootfs (`/usr/lib/linux-u-boot-*/`) and `dd`'d onto the NixOS card. Result: the handoff came alive for the
first time — `[SCP]` lines, `BL3-1: Next image address`, Linux banner. That proved every other component (kernel,
initrd, DTB, boot script, packing offsets) correct, and isolated the fault to our compiled U-Boot binary.

### Phase 6 — the last NixOS bug

The flashed image then failed differently:
`systemd-fstab-generator: Failed to create unit file '/run/systemd/generator/sysroot.mount', as it already exists.`
NixOS uses systemd inside the initrd ("systemd stage 1"), and the root filesystem was being declared twice — once by
`root=` on the kernel command line and once by the initrd's own fstab. Deleting `root=` resolved it, and the board
booted unattended into a login shell. (The command line does carry `root=fstab` today: NixOS adds it for systemd stage 1,
and it means "take the root from the initrd's fstab". What breaks is a `root=<device>` next to that fstab.)

### Phase 7 — de-blobbing, and the real U-Boot bug

The remaining compromise was that the flashed bootloader was Armbian's binary, not ours. A structured bisect followed:

- **Packing exonerated.** A TOC1 extractor script (written for this purpose, `toc1_extract.py`) confirmed the `monitor`
  and `scp` items in our package were byte-identical to Armbian's. A hybrid experiment — Armbian's compiled U-Boot item
  packed through *our* pipeline — booted. So `dragonsecboot`, `update_uboot`, `sys_config` and boot0 were all correct.
- **Toolchain theories, mostly wrong.** The bare-metal `arm-none-eabi` triple was genuinely incorrect (different enum
  and integer type widths across the blob boundary) and was replaced with `armv7l-unknown-linux-gnueabi`, matching
  Armbian. But that alone did not fix the boot. Nor did downgrading to GCC 13, matching Armbian's compiler generation.
- **`sunxi_ubootools` — a wrong turn.** A stubbed-out proprietary tool was suspected of failing to stamp a `dtb_offset`
  field, and was emulated under QEMU. A live memory dump then showed Armbian's *working* binary has `dtb_offset = 0` —
  the tool never runs in their build either. Reverted to the stub.
- **Instrumentation.** With the code path in doubt, `printf` statements were injected around each call in
  `boot_jump_linux`. The crash was localized precisely: it happened inside **`cleanup_before_linux()`**, before the DRM
  flush, before any SMC. The SMC, BL31 and monitor were never involved — disabling the ARISC SMC entirely produced the
  identical crash.
- **Root cause: frame pointers.** Disassembling both binaries side by side showed the difference immediately:

  ```text
  Armbian (works):                 Ours (crashed):
    movs r0, #3                      push {r7}          <-- frame pointer
    b.w  cleanup_..._select          movs r0, #3
                                     add  r7, sp, #0
                                     mov  sp, r7
                                     pop  {r7}
  ```

  `cleanup_before_linux_select()` flushes the D-cache and then disables it. U-Boot's own source comment states this is
  safe *only because nothing is pushed onto the stack in between*. A frame-pointer prologue does exactly that: it writes
  to the stack after the flush; those cache lines are dirty when the cache is disabled without writeback; the popped
  return address comes back as garbage; the CPU branches into nowhere. Ubuntu's `arm-linux-gnueabi-gcc` (which Armbian
  uses) omits the frame pointer by default at `-O2`; every nixpkgs ARM cross-GCC keeps it. U-Boot passes
  `-fomit-frame-pointer` only to `HOSTCFLAGS`, never to the target build, so it must be supplied explicitly — via
  `KCFLAGS`, which the Makefile appends to `KBUILD_CFLAGS`.

  With that one flag, the board booted on a from-source U-Boot. **`DBG6: after cleanup`** — the instrumentation line
  that had never appeared — was the moment the port was finished.

A note on the crash address `0x17000`: for several rounds it was treated as meaningful, because it happens to equal a
`#define` for the SoC's non-secure Boot ROM base. Grepping the tree eventually showed **no code ever branches there**.
It was simply where a corrupt return address happened to point — deterministically, because the inputs were
deterministic, which is why the register dump was byte-identical across every build and misled the investigation for a
long time.

### Phase 8 — the boot countdown that ignored its own configuration

With the board booting, `CONFIG_BOOTDELAY` was raised so the `=>` prompt could be reached during a failure. `printenv`
reported the configured value correctly — and the board still counted down from 1.

The cause is in `common/autoboot.c`. Allwinner hardcodes, as the **first statement** of `__abortboot()`:

```c
static int __abortboot(int bootdelay)
{
	int abort = 0;
	unsigned long ts;
	bootdelay = 1;          /* discards the argument */
	printf("Hit any key to stop autoboot: %2d ", bootdelay);
```

Both `CONFIG_BOOTDELAY` and the `bootdelay` environment variable are read correctly by `bootdelay_process()` and then
thrown away one function call later. The fix is a `postPatch` `sed` deleting that line, guarded by a `grep` that fails
the build if the vendor ever renames it. This matters more than it sounds: the `=>` prompt is this board's only recovery
mechanism.

(Two useful facts discovered in the same file: any keypress during the countdown aborts, so even a 1-second window is
usable if you spam a key; and holding `s` — the vendor reads up to three `s`/`S` presses — drops to the shell and sets
"boot debug mode".)

---

## 5. Part B — the unattended installer and the move to NVMe

### 5.1 The constraint that shapes everything

The BROM reads the first-stage loader only from SD/eMMC raw sectors. It has no PCIe stack and no USB mass-storage
support. Therefore:

- **USB boot does not exist on this board.** The GMKTec pattern (build an ISO, boot it from a USB stick, install to
  NVMe) cannot be transplanted.
- **The SD card can never be removed.** Even with everything else on the SSD, the card must remain to supply boot0 and
  the boot package.

The resulting design is a hybrid: the **SD card is the boot device forever**, and the
**NVMe SSD is the root filesystem**. The installer is an SD image; after it runs, the SD holds only boot artifacts.

An eMMC module would be the only route to a card-free board (the BROM reads eMMC too), but the board has no eMMC fitted
— the boot log's `MMC Device 2 not found` is the SoC looking for it.

### 5.2 Module structure

The original single hardware module was split in three, because the installer and the installed system need the same
boot chain but incompatible root filesystems:

| File | Role |
|---|---|
| `config-physical-opi4pro-common.nix` | The entire boot chain: vendor U-Boot, vendor kernel, the bootloader install hook, `opi4pro-flash-uboot`. Imported by **both** the installer and the installed system. Deliberately does **not** import `sd-image.nix`. |
| `opi4pro-boot-files.nix` | What the FAT partition holds and the tools that write it: the static `boot.scr`, the menu writer, the card assembler, `opi4pro-boot-card`. Added with the boot menu (§7); used by the hook, both images and the card script alike. |
| `config-physical-opi4pro.nix` | The installed system: imports the common module plus disko, and declares the NVMe layout. |
| `setup-opi4pro.nix` | `mkOpi4ProInstallerImage`: builds the installer SD image. Imports the common module plus `sd-image.nix`. |
| `setup-opi4pro-boot-image.nix` | `mkOpi4ProBootImage` and `mkOpi4ProBootCard`: the boot-only card for replacing a card under an already-installed system (§7), from the flake or from the running board. Imports nothing — it assembles the final system's existing boot artifacts. |

`sd-image.nix` had to be isolated to the installer because it hardcodes `fileSystems."/"` to the `NIXOS_SD` label, which
collides with the disko-managed NVMe root.

`lib.nix` gained a two-line branch: machines with `imgIsInstaller = true` get an installer image from
`mkOpi4ProInstallerImage`; everything else keeps the existing full-system `mkSdCardImage` path. Package names are
unchanged (`opi4pro_img` → `opi4pro.img.zst`), so the `Makefile` needed no modification.

### 5.3 Moving `boot.scr` to the FAT partition

Previously `boot.scr` lived at `/boot/boot.scr` on the ext4 root. Once the root moved to NVMe, that would have meant the
SD card still carrying an ext4 filesystem purely to hold one 700-byte file. So `boot.scr` moved onto the FAT firmware
partition alongside the kernel, initrd and DTB.

That required one non-obvious change. U-Boot's distro-boot logic runs `part list mmc 0 -bootable` and scans
**only bootable partitions**, looking for `boot.scr` under the prefixes `/` and `/boot/`. nixpkgs' `sd-image.nix` marks
the *root* partition bootable. The installer image therefore runs `sfdisk --activate $img 1` in `postBuildCommands`,
which turns the bootable flag on for partition 1 and off for every other partition.

**Migration note for cards built before this change:** the install hook now writes `boot.scr` to the FAT partition, but
an old card still has the bootable flag on partition 2 and an old `boot.scr` there, so it will silently keep booting the
old generation. Fix with `sudo sfdisk --activate /dev/mmcblk1 1`, or reflash.

### 5.4 The lean image, and the install-loop question

The full system closure is ~6 GB and growing; the target SD card is 4 GB. So unlike the ISO flow, the installer image
embeds **only the flake source** (`inputs.self` copied to `/etc/nixos`), plus disko's small closure. Everything heavy is
substituted from the attic cache at install time.

This creates a hard prerequisite: **the final system's closure must be pushed to the cache before the installer runs**,
or `nixos-install` will attempt to build the vendor kernel and U-Boot on the board.

The mechanism that prevents an install loop is worth stating explicitly, because it is not obvious: `nixos-install` runs
`switch-to-configuration boot` inside the chroot, which invokes the target system's `boot.loader.external.installHook`.
The installer bind-mounts the SD's FAT partition at `/mnt/boot/firmware` beforehand, so that hook
**rewrites the boot menu with the installed system as its default entry, and deletes the installer's files**. (Before
the menu, it overwrote the installer's kernel, initrd, DTB and `boot.scr` with the installed system's.) The next boot
goes straight into the installed system. No kexec is used — kexec on this vendor kernel is untested, and a plain reboot
exercises exactly the path the system will use forever after.

### 5.5 Six installer bring-up failures

Every one of these was a difference between "a minimal installer environment" and "a fully configured server", and each
is worth recording because the same class of problem will recur on the next board.

**1. `getent` not found.** The unattended-install service's `path` lacked it. Added `pkgs.getent`.

**2. `resolvconf update` failed; no DNS.** The installer inherited the scripted-`dhcpcd` path while `systemd-resolved`
owned `/etc/resolv.conf`, so the resolver file was never populated.

**3. DHCP address but no DNS server.** After enabling `services.resolved`, `resolvectl status` showed no `DNS` scope on
the link and no default route — only the global Cloudflare fallback. The root cause: `networking.useDHCP` selects the
**scripted dhcpcd** backend unless `useNetworkd` is set, and dhcpcd does not hand DHCP-learned DNS to resolved. The
servers in this fleet all set `useNetworkd = true`, which makes the same `useDHCP = true` mean *networkd* DHCP — which
plumbs DNS into resolved over D-Bus. Adding `networking.useNetworkd = true` fixed it. This mattered specifically because
the binary cache is an **internal** name: falling back to public DNS resolved nothing.

**4. TLS failures: "certificate is not yet valid".** The board has no battery-backed RTC, so it boots with a clock in
the past; every certificate's `notBefore` looks like the future. By the time anyone logs in to check,
`systemd-timesyncd` has corrected the clock, hiding the cause. Fixed by enabling timesyncd and gating the installer on
`time-sync.target` plus an explicit `NTPSynchronized` poll.

**5. disko silently skipped `mkfs`.** This is the subtlest one. disko's destroy step runs `wipefs --all` on the *disk*
plus `dd bs=440 count=1` (the MBR boot-code gap). It does **not** zero the sectors where a partition's filesystem
superblock lives. Its format step is guarded by `blkid <partition> | grep -q TYPE=` — "format only if nothing is there".
Because the layout is deterministic, every re-run recreated the partition at exactly the same LBA, where the previous
attempt's superblock still sat. disko found it, concluded "already formatted", skipped `mkfs.ext4`, and then failed to
mount.

The symptom mutated as the leftovers changed: first a recurring `vfat FAT32 5BF3-D093` with an unchanging UUID (proof
that nothing was ever being written), then, after a manual `mkfs.ext4`,
`EXT4-fs: bad geometry: block count 31258449 exceeds size of device (31258368 blocks)` — a filesystem made for a
slightly larger partition than disko's `--align-end` produces.

This is not a disko bug so much as a documented sharp edge, and it only surfaces when reinstalling repeatedly onto the
same disk; a factory-blank SSD would never have shown it. The fix is a `preCreateHook` on the disk node, which uses
disko's own `$device` variable so the device name is not repeated anywhere in the configuration:

```nix
    preCreateHook = ''
      dd if=/dev/zero of="$device" bs=1M count=16 conv=fsync
    '';
```

**6. Attic returned HTTP 401.** The private cache requires authentication that the installer does not have, so nix
dropped that substituter for the whole run. The install still succeeded — and quickly — for two reasons worth
understanding: the bulk of the closure (~4.6 GiB) is stock nixpkgs and came from `cache.nixos.org`; and the
board-specific heavy derivations (vendor kernel, U-Boot) were **already in the installer's own store**, because the
installer boots the very same kernel. Roughly 342 cheap derivations were built on-device. If a future configuration
needs a server-only prebuilt path, this will need fixing — attic authentication is a `netrc-file`, which (like the age
key) cannot live in the Nix store and must be delivered out of band.

A related note: the installed system's `setupSecrets` activation fails during `nixos-install` because the sops age key
is not yet present. That is expected — the key arrives on a USB stick at first boot — but "install finished" is
therefore *not* the acceptance test. The acceptance test is a first boot with the key present, reaching a working sshd.

### 5.6 The resulting layout

| Location | Contents |
|---|---|
| SD raw offset 8 KiB | `boot0_sdcard.fex` (DRAM init) |
| SD raw offset 16400 KiB | `boot_package.fex` (U-Boot + BL31 + SCP) |
| SD partition 1 — FAT, label `FIRMWARE`, starts 48 MiB, **bootable** | `boot.scr` and the boot menu: `menu/extlinux.conf`, with the kernels, initrds and DTBs it loads under `menu/nixos/` (§7). 3 GiB on a boot-only card, 256 MiB on the installer's. Before the menu: `Image`, `uInitrd`, `allwinner/sun60i-a733-orangepi-4-pro.dtb`, `boot.scr` |
| SD partition 2 — ext4, label `NIXOS_SD` | the installer's root; dead weight after installation, and omitted entirely by the boot-only card (§7) |
| NVMe `/dev/nvme0n1` — GPT, one ext4 partition, label `NIXOS_ROOT`, partlabel `disk-main-nixos` | `/`, `/nix`, everything else |

No ESP (this board does not boot via UEFI), no swap (zram), no encryption — the board has no TPM and boots must be
unattended.

---

## 6. Part C — USB-2 host mode

The board's single USB-A port worked only for USB-3 devices. USB-2 devices were invisible. The manufacturer's Debian
image had no such problem, which proved the hardware was fine.

`lsusb -t` told the story. Debian showed six buses; NixOS showed four. Both had the two xHCI buses (10000M and its 480M
companion). The missing pair was one **EHCI + OHCI** set — the USB-2 half of the combo port.

The device trees turned out to be *identical* in the relevant respect: on both systems all four controllers
(`ehci0@4101000`, `ohci0@4101400`, `ehci1@4200000`, `ohci1@4200400`) were `status = "okay"` and all four probed. Both
kernels had the same USB config. The difference was one line in the boot log:

```text
Debian:  sunxi:sunxi_usbc:[INFO]: insmod_host_driver
         sunxi:ehci_sunxi:[INFO]: [ehci0-controller]: sunxi_usb_enable_ehci
NixOS:   (never happens)
```

`ehci0`/`ohci0` deliberately start parked (`Not init ehci0`). They are the USB-2 companion of a port whose role is
decided by the sunxi **OTG manager** (`usbc0@10`). Both systems log the manager failing to determine that role:

```text
sunxi_usbc: OTG can't find bcten-gpio, use default mode.
sunxi_usbc: get id is fail, -61
sunxi_usbc: ERR: usb detect mode isn't supported
```

The board has **no ID-pin GPIO** (`usb_id_gpio;` is declared empty in the DTS), so detection cannot succeed. What
differed was the fallback: Debian's default resolved to host and called `insmod_host_driver`; this build's did not.

The runtime proof was immediate — writing `1` to `/sys/devices/platform/soc@3000000/10.usbc0/otg_role` produced exactly
the missing sequence and a USB-2 flash drive enumerated on the newly created bus 5. (The knob accepts `0` = device,
`1`/`usb_host` = host, `2` = OTG/device; the words `host` and `device` are rejected with `Invalid argument`.)

The permanent fix is two device-tree properties. The board DTS (`sun60i-a733-orangepi-4-pro.dts`) already overrides
`&usbc0` — so the shared `sun60iw2p1.dtsi` is left untouched, and the sibling zero3w board is unaffected:

```text
usb_port_type   = <0x2>;   →  <0x1>    /* OTG port      → fixed host port   */
usb_detect_type = <0x1>;   →  <0x0>    /* use detection → use the fixed type */
```

Applied as a scoped `perl` edit in the kernel's `postPatch`, with a `grep` guard that fails the build if the node is
ever renamed. One trap: there is a **commented-out** `usb_detect_type = <0x1>;` inside an `#ifdef TYPEC_DP` block
immediately above the live one, so the substitution uses a negative lookahead to skip commented lines.

For boot-from-USB, a udev rule in the initrd (`ACTION=="add", SUBSYSTEM=="platform", KERNEL=="10.usbc0"`) writes the
role as soon as the manager probes — early enough for a USB root device to enumerate before stage 1 looks for it.

**Trade-off:** `usb_detect_type = <0x0>` disables role detection entirely, making the port host-only. USB gadget/device
mode on the Type-C port is foreclosed. For a headless server that is the right choice.

---

## 7. Operating the system

### Deploying a change

Everything is built on the x86 workstation and pushed; the board never builds. Because the board is not a trusted Nix
user, the closure must be **signed recursively** — signing only the top-level path is the most common mistake here:

```bash
nix build .#nixosConfigurations.opi4pro.config.system.build.toplevel --no-link --print-out-paths \
  | xargs nix store sign --key-file ~/.config/nix/giggio.key --recursive

nixos-rebuild switch --flake .#opi4pro --target-host <user>@<board> --use-remote-sudo
```

Verify the closure is fully signed before pushing:

```bash
nix path-info --recursive --sigs-required 1 \
  .#nixosConfigurations.opi4pro.config.system.build.toplevel > /dev/null && echo "closure fully signed"
```

The other way, the one used for the boot menu's rollout: push the closure to the attic cache (`make cache_<machine>`),
then run `nixos-rebuild switch` on the board, from its own clone of the configuration, which substitutes everything.

### What a `switch` does and does not update

`nixos-rebuild switch` runs the install hook, which rewrites the **boot menu** on the FAT partition: it copies any kernel,
initrd or DTB the menu does not have yet, writes `menu/extlinux.conf` with the new system as the default entry and the
20 newest generations after it, installs the static `boot.scr`, and deletes the files no entry loads any more. Watch
for these lines; if they do not appear, the board will reboot into the old system:

```text
opi4pro: writing the boot menu to /boot/firmware/menu (default entry + up to 20 generations)
opi4pro: 21 menu entries, 1 files copied
opi4pro: bootloader on card is up to date
opi4pro: bootloader install complete
```

The order is the safety: the files are copied first, the conf is replaced in one rename, and only then is anything
deleted, so a hook that fails part of the way (a full partition, say) leaves the previous menu complete. A switch that
fails in the hook prints `Failed to install bootloader` and does not activate the new system, but nixos-rebuild has
already set the profile, so a generation exists that never ran. It is harmless, and shows up in the menu like any other.

On a FAT partition under 1 GiB (an installer card, or one made before the menu) the hook keeps only one older generation:
that is what fits next to the old layout's files while it converts a card. A boot-only card (below) has room for 20.

It does **not** touch the raw bootloader sectors. U-Boot lives outside every filesystem, so any change to the U-Boot
derivation (defconfig, `KCFLAGS`, patches, bootdelay) has no effect until flashed separately:

```bash
sudo opi4pro-flash-uboot --check    # reports whether the card matches the current configuration
sudo opi4pro-flash-uboot            # writes both raw regions and verifies the readback
sudo reboot
```

This is safe on a running board: the bootloader region ends around 17.8 MiB and partition 1 starts at 48 MiB, so nothing
mounted is being written. Flashing is deliberately *not* automatic on every switch — a bad U-Boot is the one failure
that costs a card pull, so that step stays explicit.

### The boot menu (October 2026)

Until October 2026 the hook wrote one `Image`, one `uInitrd`, one DTB and a `boot.scr` with that generation's
`init=/nix/store/...` baked in. The card booted exactly one generation, and rolling back meant mounting both disks on a
PC and rebuilding those four files by hand. The pi4 has a menu because its mainline U-Boot finds an `extlinux.conf`; the
assumption had been that this vendor U-Boot could not.

It can. `sun60iw2p1_t736_defconfig` has `CONFIG_CMD_PXE` (which provides `sysboot` and selects `MENU`) and
`CONFIG_DISTRO_DEFAULTS` (which selects raw-initrd support), and Allwinner had even patched `cmd/pxe.c` to pad the FDT by
8 KiB after loading it. What it has besides are three traps, each found the hard way:

1. **No memory map.** The default environment sets no `fdt_high`/`initrd_high`, so an extlinux entry booted as-is
   relocates the initrd across BL31 — Phase 4 again. And distro boot looks for `extlinux/extlinux.conf` under `/` and
   `/boot/` *before* it looks for `boot.scr`, so a conf in either place would be booted without the map. So `boot.scr`
   stays, now static: it sets the memory map (plus `pxefile_addr_r = 0x4a800000`, between the FDT and the initrd) and
   runs `sysboot mmc 0:1 any ${pxefile_addr_r} /menu/extlinux.conf`, a path the scan never looks at. The `fdt resize
   65536` of the old script went: measured on the board, U-Boot adds ~700 bytes to the DTB, against the vendor's 8 KiB.
2. **A 127-character path limit.** The first test card listed every generation, then skipped every one of them with
   `Base path too long`. `pxe.c` refuses any path longer than `MAX_TFTP_PATH_LEN` = 127, conf directory included, and
   nixpkgs' extlinux builder names each file after its whole store path: the DTB's came to ~155 characters. So the menu
   is written by our own `opi4pro-write-menu`, with absolute paths named by store hash — `/menu/nixos/<hash>-Image`,
   `-initrd` and `-dtb`, about 50 characters. (That same card also showed that an entry which fails to load falls
   through to the next one, which is a free fallback.)
3. **A menu timeout that does not wait.** The same card printed `Enter choice:` and went straight on. `cli_readline`
   waits until `endtick(seconds)` = `get_ticks() + seconds * get_tbclk()`, and Allwinner's
   `arch/arm/cpu/armv7/sunxi/timer.c` returns the raw 24 MHz arch counter from `get_ticks()` but `CONFIG_SYS_HZ` (1000)
   from `get_tbclk()`. One "second" lasts 1/24000 of a second, so the conventional `TIMEOUT 50` is 0.2 ms. The autoboot
   countdown never showed it because it uses `get_timer()`, which divides properly. The fix is on the card, not in
   U-Boot: `TIMEOUT 1200000`, which is 5 seconds here. The 24 MHz is measured (`clock-frequency = <0x16e3600>` on the
   live timer node), and `tests/opi4pro-boot-menu.nix` greps the vendor source for the timer code and the path limit, so
   a fixed U-Boot cannot meet the scaled timeout unnoticed — it would wait 33 hours at the menu after a power cut.

The second test card booted. The rollout then failed once more, on the board's first switch with the new hook:
`bash: command not found`, then `Failed to install bootloader`. `switch-to-configuration` runs the hook with a `PATH`
that has none of the system's tools, and the hook ran a plain script with a bare `bash`. The build sandbox, where the
check runs, has `bash` on `PATH`, so the check had passed. The hook now carries its own `bash` and `sed`, and the check
runs it under `env -i`. Nothing reached the card in that failure, which is what the hook's ordering is for.

Two things about the menu that are easy to get wrong at the console:

- **The number to type is the entry's position in the list, not the generation number.** For generation 46, listed
  after `Default`, 48 and 47, it is `4`; typing `46` answers `46 not found` and shows the menu again.
- **Any keypress stops the countdown**, and the menu then waits for a choice; with no input it boots `Default`.

`modules/opi4pro-boot-files.nix` holds the layout and these reasons next to the code, and
[`DISASTER-RECOVERY.md`](./DISASTER-RECOVERY.md) §5 how to use the menu to roll back.

### Replacing the SD card

The SD card is permanent, so it wears out (about every two years here), and the first card was larger than the design
needs. Neither should require reinstalling — and on inspection, nothing about the installed system depends on the card
beyond the boot chain:

```text
mmcblk1p1     3G  FIRMWARE   vfat   /boot/firmware   <- boot.scr and the menu
nvme0n1p1 119.2G  NIXOS_ROOT ext4   /                <- the actual system
```

A card written by the installer also has a partition 2 (`NIXOS_SD`, the installer's root), which nothing in the
installed configuration references. So a **boot-only card** carries only what matters: the two raw bootloader regions,
and one bootable FAT partition at the same 48 MiB offset, 3 GiB, with `boot.scr` and the menu. The image is ~3.05 GiB
uncompressed, 50–150 MiB compressed, and fits a 4 GB card. Flashing it destroys nothing. There are two builders:

- **`<machine>boot_card`** (`make boot_card_<machine> BOARD=<ssh target>`), the normal way. It reads the running board's
  generations over ssh — read-only, no sudo — and writes the same menu the board's own hook would, with the same code,
  checking every copied file against its sha256 on the board. Every entry is on the NVMe by construction.
- **`<machine>boot_img`**, for when the board is down. A pure `nix build` from one flake revision, with one menu entry:
  that revision's system, which must already be on the NVMe. Build it from the revision the board was last running.

Both read the whole FAT partition back before compressing, and a flashed card is checked against its image with one
`cmp` over the first 3120 MiB. `boot.scr` is the same on every card and every switch, so there is nothing per-card to
compare beyond that. [`DISASTER-RECOVERY.md`](./DISASTER-RECOVERY.md) §7 has the commands.

Before the menu, the boot-only image was 304 MiB carrying the four files, tied to one generation, and verified by
hashing those four files against a running system's `/boot/firmware`. Getting them byte-identical took two fixes: the
`boot.scr` derivation had to strip its own explanatory comments (it was 1872 bytes against the hook's 788, for the same
commands), and both `mkimage` call sites had to pin `SOURCE_DATE_EPOCH`, because the legacy header's `ih_time` feeds its
CRC (the first check of that passed falsely, because the dev shell exports `SOURCE_DATE_EPOCH`; it took
`env -u SOURCE_DATE_EPOCH` to see the difference). The comment stripping survives in the static `boot.scr`; the hook no
longer runs `mkimage` at all, so the timestamp question is gone with `uInitrd`.

### A known cosmetic issue

If the board's HDMI output is shared with another machine through a monitor's input switch, the vendor DRM driver flaps:
it loses HPD (hot-plug detect), re-reads a corrupt EDID (`dtd timing pixel clock[0KHz] invalid!`), caches the bad mode
and can end up unable to bring the display back until a reboot. A KVM that holds HPD/EDID on inactive ports avoids it
entirely; so does not sharing the monitor. It is a vendor-driver robustness bug, not a configuration error.

---

## 8. What remains proprietary

Three components have no public source anywhere: `boot0` (DRAM initialization), `monitor.fex` (BL31 — Allwinner's
unpublished TF-A fork for sun60iw2), and `scp.fex` (power-management core firmware). Even Armbian ships these as
binaries committed to its repository. They are irreducible today, and are fetched reproducibly by pinned hash rather
than built. Everything else — U-Boot, kernel, initrd, boot script, device tree — is compiled from source. A blob-free
boot on this SoC only becomes possible if and when mainline TF-A and U-Boot gain sun60iw2 support.

---

## 9. Glossary

| Term | Meaning |
|---|---|
| AArch32 / AArch64 | The 32-bit and 64-bit execution states of ARMv8 CPUs. Switching between them for an OS requires EL3. |
| ARISC | Allwinner's name for the SCP power-management coprocessor. |
| attic | The self-hosted Nix binary cache used by this fleet. Pushing a signed closure to it is what lets the board install without building. |
| ATF / TF-A | ARM Trusted Firmware — reference secure-world firmware for ARMv8. BL31 is its runtime stage. |
| BL31 | "Boot Loader stage 3-1" of TF-A; the secure monitor, resident at 0x48000000, servicing SMCs including the 32→64-bit kernel handoff. Called "monitor" by Allwinner. |
| boot0 | Allwinner's proprietary first-stage loader; initializes DRAM; loaded by the BROM from SD offset 8 KiB. |
| boot menu | The U-Boot menu of NixOS generations shown on serial at every boot: `menu/extlinux.conf` on the FAT partition, run by `sysboot` from `boot.scr`. Default plus the 20 newest generations; keys are list positions. |
| boot.scr | A compiled U-Boot command script (`mkimage -T script`) that U-Boot's distro-boot mechanism finds and executes. Lives on the FAT partition. Static since the boot menu: it sets the memory map and runs `sysboot`. |
| bootable flag | The MBR partition attribute U-Boot's distro-boot uses to decide which partitions to scan for `boot.scr`. Must be on partition 1 here. |
| booti / bootm | U-Boot commands: `booti` boots a raw AArch64 `Image`; `bootm` boots wrapped legacy `uImage` files and enforces their architecture tags. |
| boot-only card | An SD card carrying just the bootloader region and the FAT partition, for replacing a card without reinstalling: `<machine>boot_card` builds it from the running board, `<machine>boot_img` from the flake. Contrast with the *installer* image, which wipes the NVMe. |
| bootm pool / bootm_size | The RAM region U-Boot treats as free for boot-time staging; by default it relocates the initrd/FDT to its top. |
| BROM | Boot ROM — immutable first-instructions code in the silicon. Reads only SD/eMMC/SPI-NOR; no PCIe, no USB. |
| BSP | Board Support Package — a vendor's kernel/bootloader fork for its hardware. |
| CRC | Cyclic Redundancy Check — the checksum in uImage files; "Bad Data CRC" means the payload changed after wrapping. |
| defconfig | A named default build configuration; this board uses `sun60iw2p1_t736_defconfig`. |
| Device tree / DTS / DTB / FDT | Hardware-description data ARM kernels require. DTS is source, DTB the compiled blob, FDT the in-memory flattened form. |
| disko | The NixOS tool that declaratively partitions, formats and mounts disks. `destroyFormatMount` is the install-time entry point. |
| distro-boot | U-Boot's generic boot-media scanning convention that locates `boot.scr` on bootable partitions. |
| DRAM training | Calibration of the memory interface performed by boot0; on LPDDR5 it takes several seconds at power-on. |
| EDID | The data a display returns describing its capabilities. A corrupt read is what makes the vendor HDMI driver flap. |
| EHCI / OHCI / xHCI | USB host controller types: EHCI = USB 2.0 (480M), OHCI = USB 1.1 (12M), xHCI = USB 3 (5/10G plus a 480M companion). |
| EL0–EL3 | ARMv8 Exception Levels: EL0 user, EL1 kernel, EL2 hypervisor, EL3 secure monitor (highest). |
| extlinux | A simple boot-configuration format NixOS uses by default on ARM. Since October 2026 it is the boot menu here, run by `sysboot` from `boot.scr` rather than found by distro boot, which would skip the memory map. Written by `opi4pro-write-menu`, not nixpkgs' builder, whose paths are too long for this U-Boot. |
| .fex | Allwinner's file extension for firmware-pipeline artifacts. |
| frame pointer | A register (r7 in Thumb) holding the current stack frame's base. Its prologue pushes to the stack — fatal inside U-Boot's cache-teardown path, hence `-fomit-frame-pointer`. |
| get_ticks / get_tbclk | U-Boot's timer pair. On this vendor tree they disagree (raw 24 MHz counter against 1000 Hz), which makes the menu's timeout 24000 times too short; the conf's `TIMEOUT 1200000` compensates. |
| HPD | Hot-Plug Detect — the HDMI signal line indicating a display is attached. |
| initrd / uInitrd | The early userspace filesystem the kernel mounts first; `uInitrd` is it wrapped in U-Boot's legacy image format, which the board used until the boot menu. The menu hands U-Boot the raw initrd. |
| KCFLAGS | The make variable U-Boot appends to `KBUILD_CFLAGS` — the supported way to inject compiler flags into the target build. |
| MAX_TFTP_PATH_LEN | `pxe.c`'s limit on a path in an extlinux conf: 127 characters, conf directory included. Over it, the entry is skipped with `Base path too long`. |
| monitor_exist | A byte in U-Boot's Allwinner-specific image header (offset 0x4e9) telling it a secure monitor is resident, selecting the SMC handoff path. |
| networkd / resolved | `systemd-networkd` and `systemd-resolved`. Used together, DHCP-learned DNS reaches the resolver; with scripted dhcpcd instead, it does not. |
| OTG manager | Allwinner's `usbc0` driver, which decides whether a dual-role port acts as host or device, and gates the EHCI/OHCI controllers on that decision. |
| RTC | Real-Time Clock. This board has no battery-backed RTC, so it boots with an incorrect clock until NTP corrects it. |
| SCP | System Control Processor — auxiliary power-management core; firmware is `scp.fex`. |
| SMC | Secure Monitor Call — the ARM instruction that traps into EL3. `ARM_SVC_RUNNSOS` is Allwinner's private SMC asking BL31 to start the OS. |
| SoC | System on a Chip. The A733 (family sun60iw2) is the SoC on this board. |
| sops-nix | The secrets mechanism used by this fleet. Its age key arrives on a USB stick at first boot and is never in the Nix store. |
| SOURCE_DATE_EPOCH | The reproducible-builds environment variable `mkimage` honours for the `ih_time` field. Before the boot menu it was pinned at both boot-artifact call sites so a switch-generated file and a nix-built one came out byte-identical; now only the nix build runs `mkimage`. |
| sysboot | U-Boot's command to load and run an extlinux/syslinux conf from a filesystem (from `CMD_PXE`). `boot.scr` ends with it. |
| sys_config | An Allwinner board-description text compiled by the proprietary `script` tool and stamped into U-Boot's header by `update_uboot`. |
| systemd stage 1 | NixOS's systemd-based initrd init, which generated a duplicate `sysroot.mount` when `root=` was passed redundantly. |
| Thumb-2 | A compact ARM instruction encoding. This U-Boot is built in Thumb mode; its SMC trampoline is ARM, reached via interworking. |
| TOC1 | Allwinner's table-of-contents container format for `boot_package.fex` (64-byte header, 368-byte item records). |
| U-Boot | The bootloader; here Allwinner's 32-bit fork of U-Boot 2018.05 (banner reads 2018.07). |
| UART / serial console | The debug text channel (115200 baud) used for all observation before Linux is up. |
