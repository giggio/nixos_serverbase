{
  pkgs,
  nixosConfigurations,
  ...
}:

# Covers modules/opi4pro-boot-files.nix: what goes on the Orange Pi 4 Pro's SD card, and the tools that put it there.
#
# Nothing here can boot: qemu has no Allwinner A733, and the card's real consumer is the vendor U-Boot on the board. What CAN
# go wrong off the board, and silently, is:
#   - the card built on the PC and the board's own hook disagreeing about the menu. Both run the same two pieces, so the
#     check builds the menu both ways over the same generations and diffs them, files and all;
#   - a path U-Boot cannot load. pxe.c skips any path over 127 characters, which is what made every entry of the first
#     version fail on the board (2026-10-03);
#   - the menu's TIMEOUT. It is scaled to cancel a vendor timer bug, so the check asserts the bug is still there: a fixed
#     U-Boot with the scaled TIMEOUT would sit at the menu for 33 hours;
#   - boot.scr losing the memory map, or the menu moving to a path distro boot scans first (/extlinux or /boot/extlinux):
#     either way the board would boot an entry without `initrd_high`, relocate the initrd across BL31 and hang;
#   - the install order: a failed populate must leave the card booting what it booted before, the previous layout's files
#     may only go once the menu is in place, and files no entry loads any more must go;
#   - the card geometry: one bootable FAT partition at 48 MiB, and the U-Boot blobs at the offsets the boot ROM reads.
#
# The generations are fake: tiny files in the shape of a NixOS toplevel, three of them sharing two kernels, behind a fake
# profiles directory. The board is reached through an `ssh` stub that runs the command locally. A derivation, not a
# nixosTest: there is nothing to boot.
let
  opi4pro = nixosConfigurations.opi4pro.config;
  dtbName = opi4pro.hardware.deviceTree.name;
  bootFiles = import ../modules/opi4pro-boot-files.nix { inherit pkgs dtbName; };
  ubootSource = opi4pro.system.build.opi4proUboot.src;

  fakeKernel =
    name:
    pkgs.runCommand "linux-${name}" { } ''
      mkdir -p $out/dtbs/$(dirname ${dtbName})
      echo "kernel ${name}" > $out/Image
      echo "dtb ${name}" > $out/dtbs/${dtbName}
    '';
  kernelOld = fakeKernel "old";
  kernelNew = fakeKernel "new";

  fakeSystem =
    name: kernel:
    pkgs.runCommand "nixos-system-${name}" { } ''
      mkdir -p $out
      ln -s ${kernel}/Image $out/kernel
      ln -s ${kernel}/dtbs $out/dtbs
      ln -s ${pkgs.writeText "initrd-${name}" "initrd ${name}"} $out/initrd
      echo "init ${name}" > $out/init
      printf 'console=ttyS0,115200n8 loglevel=7' > $out/kernel-params
      printf '26.05.${name}' > $out/nixos-version
    '';
  system1 = fakeSystem "one" kernelOld;
  system2 = fakeSystem "two" kernelOld;
  system3 = fakeSystem "three" kernelNew;

  boot0 = pkgs.writeText "boot0_sdcard.fex" "fake boot0";
  bootPackage = pkgs.writeText "boot_package.fex" "fake boot package";
  assembler = bootFiles.mkCardAssembler { inherit boot0 bootPackage; };
  bootCard = bootFiles.mkBootCardScript { inherit assembler; };
  populate = "${bootFiles.populateFirmware}/bin/opi4pro-populate-firmware";

  # Like the real client, it forwards stdin to the remote command and then keeps reading it until EOF, whether the command
  # wanted any or not. A stub that left stdin alone hid a `while read` loop losing every line after the first ssh call.
  sshStub = pkgs.writeShellScriptBin "ssh" ''
    shift
    rc=0
    bash -c "$*" || rc=$?
    cat > /dev/null
    exit "$rc"
  '';
in
pkgs.runCommand "opi4pro-boot-menu"
  {
    nativeBuildInputs = with pkgs; [
      diffutils
      mtools
      util-linux
      zstd
      jq
      sshStub
    ];
  }
  /* bash */ ''
    set -euo pipefail
    export MTOOLS_SKIP_CHECK=1
    fail() { echo "FAIL: $*" >&2; exit 1; }
    conf=${bootFiles.menuDir}/extlinux.conf

    echo "== the vendor U-Boot still has the limits the menu is written around"
    timer=${ubootSource}/arch/arm/cpu/armv7/sunxi/timer.c
    grep -A3 '^ulong get_tbclk(void)' "$timer" | grep -q 'return CONFIG_SYS_HZ;' \
      || fail "get_tbclk() changed: menuTimeout in opi4pro-boot-files.nix compensates for it returning CONFIG_SYS_HZ"
    grep -A6 '^unsigned long long get_ticks(void)' "$timer" | grep -q 'mrrc p15, 0, %0, %1, c14' \
      || fail "get_ticks() no longer returns the raw arch counter that menuTimeout is scaled against"
    grep -q 'lldiv(cnt, 24000)' "$timer" || fail "the arch counter is no longer 24 MHz, menuTimeout assumes it is"
    grep -q '^#define endtick(seconds) (get_ticks() + (uint64_t)(seconds) \* get_tbclk())' ${ubootSource}/include/cli.h \
      || fail "endtick() changed, and the menu timeout with it"
    grep -q '^#define MAX_TFTP_PATH_LEN 127$' ${ubootSource}/cmd/pxe.c || fail "pxe.c's path limit changed"

    mkdir profiles
    ln -s ${system1} profiles/system-1-link
    ln -s ${system2} profiles/system-2-link
    ln -s ${system3} profiles/system-3-link
    ln -s system-3-link profiles/system

    echo "== the hook writes the menu"
    mkdir hook
    # With an empty environment, as switch-to-configuration runs the hook. The build sandbox has bash, sed and coreutils on
    # PATH, the switch does not: a populate that called a bare `bash` passed here and failed every switch on the board.
    env -i ${populate} hook ${system3} ${toString bootFiles.menuGenerations} "$PWD/profiles"
    cat hook/$conf
    [ "$(grep -c '^LABEL' hook/$conf)" = 4 ] || fail "expected the default entry plus three generations"
    [ "$(find hook/${bootFiles.menuDir}/nixos -name '*-Image' | wc -l)" = 2 ] \
      || fail "two generations share a kernel, so the menu should carry two kernels"
    [ "$(find hook/${bootFiles.menuDir}/nixos -type f | wc -l)" = 7 ] \
      || fail "expected 2 kernels, 3 initrds and 2 DTBs"
    grep -q '^TIMEOUT ${toString bootFiles.menuTimeout}$' hook/$conf || fail "TIMEOUT is not the scaled one"
    grep -q "^  APPEND init=${system3}/init console=ttyS0,115200n8 loglevel=7$" hook/$conf \
      || fail "the default entry is not the system being installed, with its kernel-params"
    grep -E '^  (LINUX|INITRD|FDT) ' hook/$conf | while read -r _ path; do
      [ "''${#path}" -le 127 ] || fail "$path is ''${#path} characters, pxe.c refuses anything over 127"
      case "$path" in
        /${bootFiles.menuDir}/nixos/*) ;;
        *) fail "$path is not an absolute path under /${bootFiles.menuDir}/nixos" ;;
      esac
      [ -f "hook$path" ] || fail "$path is in the menu but not on the card"
    done

    echo "== the card script writes the same menu"
    mkdir card
    OPI4PRO_PROFILES_DIR="$PWD/profiles" ${bootCard}/bin/opi4pro-boot-card board card/card.img.zst
    zstd --quiet -d card/card.img.zst -o card.img
    mkdir extracted
    mcopy -s -n -i card.img@@${toString bootFiles.firmwareOffsetMiB}M '::/*' extracted/
    diff -r hook extracted || fail "the card from the PC differs from what the board's hook writes"

    echo "== the card geometry"
    sfdisk --json card.img > table.json
    [ "$(jq '.partitiontable.partitions | length' table.json)" = 1 ] || fail "the card should have exactly one partition"
    [ "$(jq -r '.partitiontable.label' table.json)" = dos ] || fail "the card should have an MBR"
    [ "$(jq '.partitiontable.partitions[0].start' table.json)" = $(( ${toString bootFiles.firmwareOffsetMiB} * 2048 )) ] \
      || fail "the FAT partition should start at ${toString bootFiles.firmwareOffsetMiB} MiB"
    [ "$(jq '.partitiontable.partitions[0].size' table.json)" = $(( ${toString bootFiles.firmwareSizeMiB} * 2048 )) ] \
      || fail "the FAT partition should be ${toString bootFiles.firmwareSizeMiB} MiB"
    [ "$(jq '.partitiontable.partitions[0].bootable' table.json)" = true ] || fail "partition 1 must carry the bootable flag"
    mlabel -s -i card.img@@${toString bootFiles.firmwareOffsetMiB}M :: | grep -q "Volume label is FIRMWARE *$" \
      || fail "the system mounts /boot/firmware by the label FIRMWARE"
    cmp <(dd if=card.img bs=1k skip=${toString bootFiles.boot0OffsetKiB} count=1 status=none | head -c "$(stat -c %s ${boot0})") ${boot0} \
      || fail "boot0 is not at ${toString bootFiles.boot0OffsetKiB} KiB"
    cmp <(dd if=card.img bs=1k skip=${toString bootFiles.bootPackageOffsetKiB} count=1 status=none | head -c "$(stat -c %s ${bootPackage})") ${bootPackage} \
      || fail "the boot package is not at ${toString bootFiles.bootPackageOffsetKiB} KiB"

    echo "== boot.scr sets the memory map, then hands over to a menu distro boot does not scan"
    cmp hook/boot.scr ${bootFiles.bootScript} || fail "the card's boot.scr is not the static one"
    # A legacy script image: a 64-byte header, then a table of part lengths ending in a zero word, then the script.
    tail -c +73 ${bootFiles.bootScript} > boot.cmd
    cat boot.cmd
    ! grep -q '#' boot.cmd || fail "the comments should have been stripped"
    conf_path="$(sed -n 's|^sysboot mmc 0:1 any ''${pxefile_addr_r} \(.*\)$|\1|p' boot.cmd)"
    [ "$conf_path" = /$conf ] || fail "boot.scr does not hand over to the menu"
    case "$conf_path" in
      /extlinux/extlinux.conf | /boot/extlinux/extlinux.conf)
        fail "distro boot would find $conf_path before boot.scr, and boot it without the memory map" ;;
    esac
    [ ! -e extracted/extlinux ] && [ ! -e extracted/boot ] || fail "the card has a conf where distro boot looks first"
    sysboot_line="$(grep -n '^sysboot' boot.cmd | cut -d: -f1)"
    [ "$(tail -n 1 boot.cmd)" = "$(grep '^sysboot' boot.cmd)" ] || fail "sysboot should be the last command"
    for setting in "kernel_addr_r 0x41000000" "fdt_addr_r 0x4a000000" "pxefile_addr_r 0x4a800000" \
      "ramdisk_addr_r 0x4b000000" "fdt_high 0xffffffff" "initrd_high 0xffffffff"; do
      line="$(grep -n "^setenv $setting\$" boot.cmd | cut -d: -f1)" || fail "boot.scr does not set $setting"
      [ "$line" -lt "$sysboot_line" ] || fail "boot.scr sets $setting after sysboot"
    done

    echo "== a later switch drops the files no entry loads any more"
    ${populate} hook ${system3} 0 "$PWD/profiles"
    [ "$(grep -c '^LABEL' hook/$conf)" = 1 ] || fail "with no generations the menu should have the default entry only"
    [ "$(find hook/${bootFiles.menuDir}/nixos -type f | wc -l)" = 3 ] \
      || fail "the kernel, initrd and DTB of the older generations should be gone"

    echo "== populate replaces the previous layout, in order"
    mkdir -p firmware/allwinner
    echo old > firmware/Image
    echo old > firmware/uInitrd
    echo old > firmware/allwinner/board.dtb
    echo "old boot.scr" > firmware/boot.scr
    cp -r firmware firmware-before

    # A partition that cannot take the menu: writing it fails, and the card must still boot what it booted before.
    mkdir firmware/${bootFiles.menuDir}
    chmod a-w firmware/${bootFiles.menuDir}
    if ${populate} firmware ${system3} 0; then
      fail "populate succeeded on a menu directory it cannot write"
    fi
    chmod u+w firmware/${bootFiles.menuDir}
    rmdir firmware/${bootFiles.menuDir}
    diff -r firmware-before firmware || fail "a failed populate changed the card"

    ${populate} firmware ${system3} 0
    cmp firmware/boot.scr ${bootFiles.bootScript} || fail "populate did not install the static boot.scr"
    for legacy in Image uInitrd allwinner; do
      [ ! -e "firmware/$legacy" ] || fail "populate left the previous layout's $legacy behind"
    done

    touch $out
  ''
