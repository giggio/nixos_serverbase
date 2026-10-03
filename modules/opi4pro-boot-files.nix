# What the Orange Pi 4 Pro's SD card carries, and the tools that write it. One definition, used by four consumers:
#   - the bootloader install hook (config-physical-opi4pro-common.nix), on every `nixos-rebuild switch` and `nixos-install`;
#   - the installer image (setup-opi4pro.nix), for the installer's own boot;
#   - the boot-only card image (setup-opi4pro-boot-image.nix), built purely from one flake revision;
#   - `opi4pro-boot-card`, which builds the same card on the PC from the generations a running board already has, over ssh.
# All of them write the menu with the same two pieces, listGenerations and opi4pro-write-menu, so a card built on the PC and
# the board's next switch agree by construction. tests/opi4pro-boot-menu.nix runs all of it against fake generations.
#
# THE LAYOUT. The FAT partition (label FIRMWARE, partition 1, bootable) holds:
#   boot.scr              static; sets the memory map, then hands over to the menu with `sysboot`
#   menu/extlinux.conf    one entry per generation
#   menu/nixos/           the kernels, initrds and DTBs those entries load, named <store hash>-Image/-initrd/-dtb
#
# WHY A MENU NEEDS A BOOT SCRIPT IN FRONT OF IT. The vendor U-Boot already has extlinux support (`CMD_PXE` gives `sysboot` and
# selects `MENU`; `DISTRO_DEFAULTS` gives raw initrds), but its default environment does not set `fdt_high`/`initrd_high`.
# Without them U-Boot relocates the ~40 MiB initrd to the top of its bootm pool, straight across BL31 at 0x48000000, and the
# board hangs after "Starting kernel ..." (bring-up phase 4). So boot.scr sets the memory map first and calls `sysboot` itself.
#
# WHY `menu/extlinux.conf`. Distro boot runs `scan_dev_for_extlinux` BEFORE `scan_dev_for_scripts`, looking for
# `extlinux/extlinux.conf` under the prefixes "/" and "/boot/". A conf at either place would be booted directly, without
# boot.scr's memory map, and hang. The scan never looks at `menu/extlinux.conf`.
#
# WHY NOT NIXPKGS' extlinux-conf-builder, which the first version used (2026-10-03). Two limits of this U-Boot, both found by
# booting it:
#   - pxe.c refuses any path over MAX_TFTP_PATH_LEN = 127 characters, conf directory included ("Base path too long"). The
#     builder names files after their whole store path, and `../nixos/<hash>-linux-...-sun60iw2-dtbs/allwinner/<board>.dtb`
#     from `/menu/extlinux/` is ~155. Every entry was skipped. The paths here are absolute and ~75 characters long.
#   - The menu's TIMEOUT does not wait. See menuTimeout below.
{
  pkgs,
  # The DTB the menu entries load, relative to the generation's dtbs/ directory. Comes from hardware.deviceTree.name; the
  # default only serves the test.
  dtbName ? "allwinner/sun60i-a733-orangepi-4-pro.dtb",
}:

rec {
  menuDir = "menu";
  menuTimeoutSeconds = 5;

  # What goes in the conf's TIMEOUT to make the menu wait menuTimeoutSeconds. Not the 50 any other U-Boot would want.
  # pxe.c turns TIMEOUT (tenths of a second) into whole seconds, and cli_readline waits until `endtick(seconds)`, which is
  # `get_ticks() + seconds * get_tbclk()`. Allwinner's arch/arm/cpu/armv7/sunxi/timer.c returns the raw 24 MHz arch counter
  # from get_ticks() but CONFIG_SYS_HZ (1000) from get_tbclk(), so one "second" there lasts 1/24000 of a second: TIMEOUT 50
  # gave the board 0.2 ms, and it booted the default entry without stopping (2026-10-03). Scaling by 24000 cancels that.
  # The counter frequency is measured, not assumed: the board's live device tree has `clock-frequency = <0x16e3600>`
  # (24 MHz) on its arm,armv8-timer node, and the same timer.c divides by 24000 in get_timer().
  # IF U-BOOT'S get_tbclk() IS EVER FIXED, this has to go back to seconds * 10 in the same change, or the board waits 33
  # hours at the menu after every power cut. tests/opi4pro-boot-menu.nix fails when the vendor timer.c stops being the shape
  # this compensates for.
  menuTimeout = menuTimeoutSeconds * 10 * 24000;

  # How many generations the hook keeps in the menu, besides the default entry. ~65 MiB each when kernel and initrd both
  # changed (Image ~27 MiB, initrd ~40 MiB), so 20 is ~1.3 GiB at worst on a 3 GiB partition.
  menuGenerations = 20;
  # A card with a smaller FAT partition (the 256 MiB of every card made before the menu, and of the installer image, whose
  # ext4 root has to fit on the same 4 GB card) only gets the default entry and one more. Its partition also holds the old
  # Image/uInitrd/DTB until the first menu install has finished and removes them, and this is what still fits next to them.
  smallCardGenerations = 1;
  smallCardThresholdMiB = 1024;

  # The card geometry. Both raw offsets are fixed by the hardware/blob contract: the boot ROM reads boot0 from 8 KiB, and boot0
  # reads the boot package from 16400 KiB. The FAT partition starts after that region, which ends around 17.8 MiB; 48 MiB is
  # what the installer image has always used, and the system mounts the partition by label, so the two kinds of card are
  # interchangeable.
  boot0OffsetKiB = 8;
  bootPackageOffsetKiB = 16400;
  firmwareOffsetMiB = 48;
  firmwareSizeMiB = 3072;

  # Static: it names no generation, so every card and every switch carries the same bytes, and a card no longer has to be
  # built from the revision the board runs.
  bootScript = pkgs.runCommand "boot.scr" { nativeBuildInputs = [ pkgs.ubootTools ]; } /* bash */ ''
    # The comments below explain the memory map next to the lines they are about, and are stripped before mkimage: hush
    # would skip them, but they would cost bytes on every card for nobody to read.
    cat << 'EOF' > boot.cmd.annotated
    # Armbian's hardware-tested sun60iw2 memory map. BL31 (the secure monitor) is RESIDENT at 0x48000000-0x48ffffff and is
    # still needed at handoff time - U-Boot calls into it via SMC to switch the CPU to 64-bit and enter the kernel. So the
    # kernel goes BELOW it and the FDT, the menu file and the initrd go ABOVE it.
    setenv kernel_addr_r 0x41000000
    setenv fdt_addr_r 0x4a000000
    # Between the FDT (~210 KiB, padded by 8 KiB after loading) and the initrd. The default would be wherever this tree's
    # environment puts it, which nobody has measured against this map.
    setenv pxefile_addr_r 0x4a800000
    setenv ramdisk_addr_r 0x4b000000

    # fdt_high/initrd_high = 0xffffffff means "do not relocate, use in place". This is essential, not cosmetic: by default
    # U-Boot relocates the initrd to the top of its bootm pool (bootm_size=0xa000000, so the top is 0x4a000000). A 40 MB
    # NixOS initrd relocated there lands at ~0x479db000-0x49fff2b5 - directly on top of resident BL31, destroying the monitor
    # seconds before the SMC that needs it. The board then hangs silently right after "Starting kernel ...".
    setenv fdt_high 0xffffffff
    setenv initrd_high 0xffffffff

    # The menu. Each entry loads its kernel (raw Image, entered with booti), its raw initrd and the DTB to the addresses above.
    # The vendor's pxe.c pads the FDT by 8 KiB after loading it, which replaces the `fdt resize 65536` this script used to run:
    # measured on the board (2026-10-03), U-Boot adds ~700 bytes to it (bootargs and the initrd range).
    # An entry that fails to load is skipped and the next one tried, in menu order. If sysboot returns - the conf is
    # missing, every entry failed, or Ctrl-C at the menu - distro boot carries on and ends at the `=>` prompt.
    sysboot mmc 0:1 any ''${pxefile_addr_r} /${menuDir}/extlinux.conf
    EOF
    sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' boot.cmd.annotated > boot.cmd
    mkimage -C none -A arm -T script -d boot.cmd boot.scr
    cp boot.scr $out
  '';

  # Lists the generations that go in the menu, one per line, tab-separated:
  #   tag, toplevel, kernel, initrd, DTB, date, nixos-version, kernel-params
  #   bash list-generations.sh <profiles dir> <generations> [default toplevel]
  # The default entry is the toplevel given (the one being installed), or the profile's current system. Then the newest
  # <generations> generations, as nixpkgs' extlinux builder picks them. A field that is missing is "-": an empty one would
  # vanish, because tab is IFS whitespace and `read` collapses consecutive tabs.
  # A plain script rather than a package, because opi4pro-boot-card runs it on the board through `ssh ... bash -s`. So it only
  # uses what any NixOS has, and it is read-only.
  listGenerations = pkgs.writeText "opi4pro-list-generations.sh" ''
    set -euo pipefail
    profiles="$1"
    generations="$2"
    default="''${3:-$profiles/system}"
    entry() {
      local path dtb=-
      path="$(readlink -f "$2")"
      [ -e "$path/kernel" ] && [ -e "$path/initrd" ] || return 0
      [ -e "$path/dtbs/${dtbName}" ] && dtb="$(readlink -f "$path/dtbs")/${dtbName}"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$path" \
        "$(readlink -f "$path/kernel")" "$(readlink -f "$path/initrd")" "$dtb" \
        "$(date "+%Y-%m-%d %H:%M" -d "@$(stat -L -c %Z "$path")")" "$(cat "$path/nixos-version")" "$(cat "$path/kernel-params")"
    }
    entry default "$default"
    if [ "$generations" -gt 0 ] && [ -d "$profiles" ]; then
      for generation in $( (cd "$profiles" && ls -d system-*-link 2> /dev/null) | sed 's/system-\([0-9]\+\)-link/\1/' | sort -n -r | head -n "$generations"); do
        entry "$generation-default" "$profiles/system-$generation-link"
      done
    fi
  '';

  # Writes a menu directory from a list made by listGenerations.
  #   opi4pro-write-menu <menu dir> <entries file> [ssh target]
  # Without a target the files are copied from the local store; with one, from that machine over ssh, and every copy is
  # checked against its sha256 there before the conf is written.
  #
  # Files are named by the store hash of what they come from, so two generations sharing a kernel share one file, and a name
  # never has to change while its contents stay the same. The ORDER is the safety: the files are copied and synced, then the
  # conf is replaced in one rename, and only then are the files no entry names any more deleted. Fails before the rename
  # (a full partition is the likely way) leave the previous menu complete.
  writeMenu = pkgs.writeShellApplication {
    name = "opi4pro-write-menu";
    # Every remote command is built here on purpose, with each path quoted by `printf %q` for the remote shell.
    excludeShellChecks = [ "SC2029" ];
    runtimeInputs = with pkgs; [
      coreutils
      diffutils
      gnused
      gnugrep
    ];
    text = ''
      if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
        echo "usage: opi4pro-write-menu <menu dir> <entries file> [ssh target]" >&2
        exit 2
      fi
      menu="$1"
      entries="$2"
      target="''${3:-}"
      mkdir -p "$menu/nixos"

      declare -A keep=()
      sources=()
      copies=()
      copied=0
      store_hash() {
        sed -n 's|^/nix/store/\([a-z0-9]\{32\}\)-.*|\1|p' <<< "$1"
      }
      # Sets $added to the file's path in the menu, and copies it there unless it already is. Not $(add ...): that would
      # run in a subshell, and the bookkeeping in keep/sources/copies would be lost with it.
      add() {
        local source="$1" suffix="$2" hash name
        hash="$(store_hash "$source")"
        [ -n "$hash" ] || { echo "ERROR: $source is not in /nix/store" >&2; exit 1; }
        name="$hash-$suffix"
        keep[$name]=1
        if [ ! -e "$menu/nixos/$name" ]; then
          if [ -n "$target" ]; then
            # ssh reads its stdin to the end, which here is the list of entries being looped over.
            ssh "$target" "cat -- $(printf '%q' "$source")" < /dev/null > "$menu/nixos/$name.partial"
            sources+=("$(printf '%q' "$source")")
            copies+=("$menu/nixos/$name")
          else
            cp -- "$source" "$menu/nixos/$name.partial"
          fi
          mv -- "$menu/nixos/$name.partial" "$menu/nixos/$name"
          copied=$((copied + 1))
        fi
        added="/${menuDir}/nixos/$name"
      }

      conf="$menu/extlinux.conf.new"
      {
        echo "# Written by opi4pro-write-menu (nixos_serverbase, modules/opi4pro-boot-files.nix). Rewritten on every switch."
        echo "DEFAULT nixos-default"
        echo "# Not tenths of a second: see menuTimeout in opi4pro-boot-files.nix. This is ${toString menuTimeoutSeconds} seconds on this U-Boot."
        echo "TIMEOUT ${toString menuTimeout}"
        echo "MENU TITLE ------------------------------------------------------------"
      } > "$conf"
      while IFS=$'\t' read -r tag path kernel initrd dtb date version params; do
        [ "$dtb" != - ] || { echo "ERROR: $path has no dtbs/${dtbName}" >&2; exit 1; }
        add "$kernel" Image
        linux_file="$added"
        add "$initrd" initrd
        initrd_file="$added"
        add "$dtb" dtb
        dtb_file="$added"
        {
          echo
          echo "LABEL nixos-$tag"
          if [ "$tag" = default ]; then
            echo "  MENU LABEL NixOS - Default"
          else
            echo "  MENU LABEL NixOS - Configuration $tag ($date - $version)"
          fi
          echo "  LINUX $linux_file"
          echo "  INITRD $initrd_file"
          echo "  APPEND init=$path/init $params"
          echo "  FDT $dtb_file"
        } >> "$conf"
      done < "$entries"
      grep -q '^LABEL' "$conf" || { echo "ERROR: no generation to put in the menu" >&2; exit 1; }
      echo "opi4pro: $(grep -c '^LABEL' "$conf") menu entries, $copied files copied''${target:+ from $target}"

      if [ "''${#copies[@]}" -gt 0 ]; then
        ssh "$target" "sha256sum -- ''${sources[*]}" < /dev/null | cut -d' ' -f1 > "$menu/remote.sha256"
        sha256sum -- "''${copies[@]}" | cut -d' ' -f1 > "$menu/local.sha256"
        if ! cmp -s "$menu/remote.sha256" "$menu/local.sha256"; then
          rm -f -- "''${copies[@]}" "$menu/remote.sha256" "$menu/local.sha256"
          echo "ERROR: the files copied from $target do not match their hashes there" >&2
          exit 1
        fi
        rm -f -- "$menu/remote.sha256" "$menu/local.sha256"
        echo "opi4pro: every copied file matches its hash on $target"
      fi

      sync
      mv -- "$conf" "$menu/extlinux.conf"
      sync
      for file in "$menu"/nixos/*; do
        name="$(basename "$file")"
        if [ -z "''${keep[$name]:-}" ]; then
          echo "opi4pro: removing $file, which no entry loads any more"
          rm -rf -- "$file"
        fi
      done
    '';
  };

  # Writes the menu and boot.scr into a firmware directory: the mounted FAT partition when the hook calls it, a staging
  # directory when an image is built.
  #   opi4pro-populate-firmware <firmware dir> <toplevel> <generations> [profiles dir]
  # <toplevel> is the default entry. <generations> is how many entries of the profiles directory (/nix/var/nix/profiles
  # unless given; only the test gives one) go in besides it; 0 reads no profile at all, which is what an image build needs.
  #
  # The ORDER is the safety: the menu is complete before boot.scr is swapped, and the files the previous layout booted from
  # (Image, uInitrd, allwinner/) are removed only after that. A failure anywhere before the swap leaves the card booting
  # exactly what it booted before.
  populateFirmware = pkgs.writeShellApplication {
    name = "opi4pro-populate-firmware";
    # Everything listGenerations runs, too: the hook runs under switch-to-configuration, whose PATH has none of it.
    runtimeInputs = with pkgs; [
      bash
      coreutils
      gnused
    ];
    text = ''
      if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
        echo "usage: opi4pro-populate-firmware <firmware dir> <toplevel> <generations> [profiles dir]" >&2
        exit 2
      fi
      fw="$1"
      toplevel="$2"
      generations="$3"
      profiles="''${4:-/nix/var/nix/profiles}"

      echo "opi4pro: writing the boot menu to $fw/${menuDir} (default entry + up to $generations generations)"
      entries="$(mktemp)"
      trap 'rm -f "$entries"' EXIT
      bash ${listGenerations} "$profiles" "$generations" "$toplevel" > "$entries"
      ${writeMenu}/bin/opi4pro-write-menu "$fw/${menuDir}" "$entries"

      cp ${bootScript} "$fw/boot.scr.new"
      mv "$fw/boot.scr.new" "$fw/boot.scr"
      sync

      for legacy in Image uInitrd allwinner; do
        if [ -e "$fw/$legacy" ]; then
          echo "opi4pro: removing $fw/$legacy, from the boot layout before the menu"
          rm -rf -- "''${fw:?}/$legacy"
        fi
      done
    '';
  };

  mkCardAssembler =
    { boot0, bootPackage }:
    pkgs.writeShellApplication {
      name = "opi4pro-assemble-card";
      runtimeInputs = with pkgs; [
        coreutils
        diffutils
        dosfstools # mkfs.vfat
        mtools # mcopy, mmd
        util-linux # sfdisk
        zstd
      ];
      text = ''
        if [ "$#" -ne 2 ]; then
          echo "usage: opi4pro-assemble-card <firmware dir> <output.img.zst>" >&2
          exit 2
        fi
        tree="$1"
        output="$2"
        [ -f "$tree/boot.scr" ] || { echo "ERROR: $tree has no boot.scr" >&2; exit 1; }
        [ -f "$tree/${menuDir}/extlinux.conf" ] || { echo "ERROR: $tree has no ${menuDir}/extlinux.conf" >&2; exit 1; }
        [ ! -e "$output" ] || { echo "ERROR: $output already exists" >&2; exit 1; }

        # Next to the output rather than in /tmp: the two images are 3 GiB each, sparse, and /tmp is often a tmpfs.
        work="$(realpath "$(mktemp -d "$(dirname "$output")/.opi4pro-card.XXXXXX")")"
        trap 'rm -rf "$work"' EXIT
        export MTOOLS_SKIP_CHECK=1

        # mkfs.vfat cannot format at an offset, so the partition is built on its own and copied in. -n FIRMWARE is
        # load-bearing: the installed system mounts /boot/firmware by that label. --invariant keeps the volume ID and
        # timestamps fixed, so a nix-built card is reproducible.
        truncate -s ${toString firmwareSizeMiB}M "$work/firmware.img"
        mkfs.vfat -F 32 --invariant -n FIRMWARE "$work/firmware.img" > /dev/null
        (
          cd "$tree"
          find . -mindepth 1 -type d | sort | while IFS= read -r dir; do mmd -i "$work/firmware.img" "::/''${dir#./}"; done
          find . -type f | sort | while IFS= read -r file; do mcopy -i "$work/firmware.img" "$file" "::/''${file#./}"; done
        )
        mkdir "$work/readback"
        mcopy -s -n -i "$work/firmware.img" '::/*' "$work/readback/"
        if ! diff -r "$tree" "$work/readback" > /dev/null; then
          echo "ERROR: the FAT partition does not read back as $tree" >&2
          diff -r "$tree" "$work/readback" >&2 || true
          exit 1
        fi
        echo "opi4pro: FAT partition written and read back ($(du -sh --apparent-size "$tree" | cut -f1) of files)"

        img="$work/card.img"
        truncate -s ${toString (firmwareOffsetMiB + firmwareSizeMiB)}M "$img"
        # MBR, not GPT: vendor U-Boot's distro-boot runs `part list mmc 0 -bootable devplist` and only scans partitions
        # carrying the bootable flag, so partition 1 must be flagged - and be the only partition, so it is the only one scanned.
        sfdisk --quiet "$img" <<EOF
        label: dos
        start=$(( ${toString firmwareOffsetMiB} * 1024 * 1024 / 512 )), size=$(( ${toString firmwareSizeMiB} * 1024 * 1024 / 512 )), type=b, bootable
        EOF
        # conv=notrunc on every write: without it dd would cut the image off at the end of what it just wrote.
        dd if="$work/firmware.img" of="$img" bs=1M seek=${toString firmwareOffsetMiB} conv=notrunc,sparse status=none
        dd if=${boot0} of="$img" bs=1k seek=${toString boot0OffsetKiB} conv=notrunc status=none
        dd if=${bootPackage} of="$img" bs=1k seek=${toString bootPackageOffsetKiB} conv=notrunc status=none

        region_matches() {
          local file="$1" offset_kib="$2" size
          size="$(stat -c %s "$file")"
          dd if="$img" bs=1k skip="$offset_kib" count=$(( (size + 1023) / 1024 )) status=none | head -c "$size" | cmp -s - "$file"
        }
        region_matches ${boot0} ${toString boot0OffsetKiB} || { echo "ERROR: boot0 did not read back" >&2; exit 1; }
        region_matches ${bootPackage} ${toString bootPackageOffsetKiB} || { echo "ERROR: boot_package did not read back" >&2; exit 1; }
        cmp -s <(dd if="$img" bs=1M skip=${toString firmwareOffsetMiB} status=none) "$work/firmware.img" \
          || { echo "ERROR: the FAT partition did not read back from the card image" >&2; exit 1; }
        sfdisk --list "$img"

        zstd --quiet -T0 -o "$output.partial" "$img"
        zstd --quiet --test "$output.partial"
        mv "$output.partial" "$output"
        echo "opi4pro: card image written to $output"
      '';
    };

  # Builds a card on the PC carrying the boot menu a running board would write for itself, read over ssh. Read-only on the
  # board: no sudo, nothing written there, the NVMe is only read.
  #   opi4pro-boot-card <ssh target> <output.img.zst>
  # It runs listGenerations on the board and opi4pro-write-menu here, fetching over ssh: the same two pieces the board's
  # hook runs, so the card's menu is the one the board's next switch would write.
  #
  # `ssh` is the caller's, not a runtime input: the board is reached with the caller's own ssh configuration and agent.
  # OPI4PRO_PROFILES_DIR replaces /nix/var/nix/profiles on the board, and only exists for the test.
  mkBootCardScript =
    { assembler }:
    pkgs.writeShellApplication {
      name = "opi4pro-boot-card";
      excludeShellChecks = [ "SC2029" ];
      runtimeInputs = with pkgs; [ coreutils ];
      text = ''
        if [ "$#" -ne 2 ]; then
          echo "usage: opi4pro-boot-card <ssh target> <output.img.zst>" >&2
          exit 2
        fi
        target="$1"
        output="$2"
        profiles="''${OPI4PRO_PROFILES_DIR:-/nix/var/nix/profiles}"
        [ ! -e "$output" ] || { echo "ERROR: $output already exists" >&2; exit 1; }
        mkdir -p "$(dirname "$output")"

        work="$(mktemp -d "$(dirname "$output")/.opi4pro-boot-card.XXXXXX")"
        trap 'rm -rf "$work"' EXIT
        tree="$work/firmware"
        mkdir -p "$tree"

        echo "opi4pro: reading the generations on $target"
        ssh "$target" "bash -s -- $(printf '%q' "$profiles") ${toString menuGenerations}" < ${listGenerations} > "$work/entries"
        ${writeMenu}/bin/opi4pro-write-menu "$tree/${menuDir}" "$work/entries" "$target"

        cp ${bootScript} "$tree/boot.scr"
        ${assembler}/bin/opi4pro-assemble-card "$tree" "$output"
        echo
        cat "$tree/${menuDir}/extlinux.conf"
      '';
    };
}
