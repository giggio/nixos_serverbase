# NixOS on the Orange Pi 4 Pro (Allwinner A733, SoC family "sun60iw2").
#
# This SoC has NO mainline Linux and NO mainline U-Boot support. The only working software stack is Allwinner's vendor BSP
# (Board Support Package), which Orange Pi ships and Armbian repackages. Everything in this file exists to reproduce, inside Nix,
# the boot chain that Armbian's build system produces — because that chain is the only one known to boot this hardware.
#
# The boot chain, in execution order:
#   1. BROM      - immutable boot ROM inside the silicon. Reads boot0 from raw SD offset 8 KiB.
#   2. boot0     - Allwinner's proprietary 1st-stage loader. Initializes LPDDR5 DRAM (the ~5s "DRAM Training" pause).
#                  Then reads boot_package.fex from raw SD offset 16400 KiB. BINARY BLOB - no public source exists.
#   3. BL31      - ARM Trusted Firmware "secure monitor". Loaded from the boot package to 0x48000000 and stays RESIDENT
#                  there for the life of the system, servicing SMC (Secure Monitor Call) requests from EL3. BINARY BLOB.
#   4. SCP       - firmware for the "arisc" power-management coprocessor, started by BL31 on request. BINARY BLOB.
#   5. U-Boot    - Allwinner's fork of U-Boot 2018.05, built as a 32-bit ARM binary even though the CPU/kernel are 64-bit.
#                  Built from source here. Loads boot.scr, then the kernel/initrd/DTB, then hands off.
#   6. Linux     - the vendor 6.6.98 aarch64 kernel, built from source here.
#
# The 32->64-bit handoff: a 32-bit program cannot enter a 64-bit kernel by itself; only EL3 can switch the CPU's execution
# state. So vendor U-Boot issues an SMC (ARM_SVC_RUNNSOS) to the still-resident BL31, which performs the switch and jumps to
# the kernel. This is why BL31 must survive intact all the way to handoff - see the memory-map notes on boot.scr below.
#
# Three blobs remain irreducible (boot0, BL31/monitor, SCP). Even Armbian ships these as committed binaries; no source exists
# anywhere. Everything else here - U-Boot, kernel, initrd, boot script - is compiled from source.
{
  lib,
  modulesPath,
  pkgs,
  config,
  ...
}:

let
  # ---------------------------------------------------------------------------------------------------------------------------
  # Cross toolchain for the 32-bit ARM vendor U-Boot.
  # ---------------------------------------------------------------------------------------------------------------------------
  # The triple must be arm-linux-gnueabi (Linux/glibc ABI), NOT arm-none-eabi (bare-metal/newlib). They differ in ABI defaults
  # that silently change struct layouts - bare-metal ARM GCC defaults to -fshort-enums (enums sized 1/2/4 bytes) while the Linux
  # triple fixes enums at 4 bytes. This code shares structures with the blob firmware across the SMC boundary, so a mismatch
  # produces garbage. The bare-metal triple also has a different __INT32_TYPE__ (long int vs int), which collides with the
  # vendor tree's own typedefs.
  #
  # This is the same triple Armbian uses (UBOOT_COMPILER="arm-linux-gnueabi-" in config/sources/families/sun60iw2.conf).
  # NOTE: the first build compiles GCC from source on the aarch64 build machine (slow - hours). It is cached afterwards.
  pkgsArmLinuxGnueabi = import pkgs.path {
    system = pkgs.stdenv.buildPlatform.system;
    crossSystem = {
      config = "armv7l-unknown-linux-gnueabi";
    };
  };

  # ---------------------------------------------------------------------------------------------------------------------------
  # Bootloader install hook: makes `nixos-rebuild switch` actually update what the board boots.
  # ---------------------------------------------------------------------------------------------------------------------------
  # Without this, `nixos-rebuild switch` would activate a new generation in RAM but every reboot would return to the system that
  # was baked into the SD image, because the kernel/initrd/DTB live on the FAT firmware partition and boot.scr has the
  # generation's /nix/store path baked into it. This hook rewrites all four artifacts on every switch.
  #
  # IMPORTANT: the boot.cmd heredoc below MUST stay in sync with the `bootScript` derivation further down. They generate the
  # same script for two different moments (switch-time vs image-build-time). If you change memory addresses in one, change both.
  installOpi4ProBootloader = pkgs.writeShellApplication {
    name = "install-opi4pro-bootloader";
    runtimeInputs = (
      with pkgs;
      [
        coreutils
      ]
    );
    text = ''
      set -euo pipefail
      toplevel="$1"
      fw=/boot/firmware

      # Refuse to run if the FAT firmware partition is not mounted - otherwise we would silently write the kernel into an empty
      # directory on the root filesystem and the board would keep booting the old kernel with no visible error.
      if ! ${pkgs.util-linux}/bin/mountpoint -q "$fw"; then
        echo "ERROR: $fw is not mounted; refusing to install bootloader files" >&2
        exit 1
      fi

      echo "opi4pro: installing kernel, initrd, dtb to $fw"
      # Raw aarch64 Image (no uImage wrapper): the boot script uses `booti`, which takes the kernel unwrapped.
      cp "$toplevel/kernel" "$fw/Image.new" && mv "$fw/Image.new" "$fw/Image"

      # The initrd, however, IS wrapped as a legacy U-Boot image ("uInitrd"). U-Boot needs the wrapper's size/compression
      # metadata to hand a ramdisk to the kernel. -C gzip must match boot.initrd.compressor below.
      ${pkgs.ubootTools}/bin/mkimage -A arm -O linux -T ramdisk -C gzip -n uInitrd -d "$toplevel/initrd" "$fw/uInitrd.new"
      mv "$fw/uInitrd.new" "$fw/uInitrd"

      mkdir -p "$fw/allwinner"
      cp "$toplevel/dtbs/allwinner/sun60i-a733-orangepi-4-pro.dtb" "$fw/allwinner/.dtb.new"
      mv "$fw/allwinner/.dtb.new" "$fw/allwinner/sun60i-a733-orangepi-4-pro.dtb"

      echo "opi4pro: regenerating /boot/boot.scr for $toplevel"
      # kernel-params is the file NixOS writes containing exactly `boot.kernelParams`. Reading it (rather than hardcoding) keeps
      # switch-time and image-time boot arguments identical.
      # NOTE: no `root=` here. NixOS uses systemd inside the initrd ("systemd stage 1"), and systemd-fstab-generator builds
      # sysroot.mount from the initrd's own fstab. Passing root= as well makes it generate the unit twice and stage 1 aborts with
      # "Failed to create unit file '/run/systemd/generator/sysroot.mount', as it already exists".
      bootargs="init=$toplevel/init $(cat "$toplevel/kernel-params")"
      tmp=$(mktemp)
      cat > "$tmp" <<EOF
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
      setenv bootargs "$bootargs"
      booti \$kernel_addr_r \$ramdisk_addr_r \$fdt_addr_r
      EOF
      ${pkgs.ubootTools}/bin/mkimage -C none -A arm -T script -d "$tmp" /boot/boot.scr.new
      mv /boot/boot.scr.new /boot/boot.scr
      rm -f "$tmp"
      sync
      echo "opi4pro: bootloader install complete"
    '';
  };

  # ---------------------------------------------------------------------------------------------------------------------------
  # Upstream sources.
  # ---------------------------------------------------------------------------------------------------------------------------
  # Armbian's build repo. We use it for four things, all of them things Armbian tested on this exact board:
  #   - the vendor kernel .config           (config/kernel/linux-sun60iw2-vendor.config)
  #   - four device-tree patches            (patch/kernel/archive/sun60iw2-opi-vendor/*)
  #   - the board-specific boot0 blob       (packages/blobs/sunxi/sun60iw2/boot0_sdcard_orangepi4pro.fex)
  #   - the board-specific sys_config blob  (packages/blobs/sunxi/sun60iw2/sys_config_orangepi.fex)
  # The last two are per-board (DRAM timing, pin muxing); Armbian's board file states there is no valid generic default.
  armbianBuild = pkgs.fetchFromGitHub {
    owner = "armbian";
    repo = "build";
    rev = "v26.8.0-trunk.343";
    hash = "sha256-/3Jl3xTsLiDmUWCBwPORB1pRkLFKz83/8MaEEtRbYXA=";
  };

  # Orange Pi's own build repo. We use it only for the proprietary x86 packing tools (external/packages/pack-uboot/tools/*) and
  # the shared SoC boot assets: boot_package.cfg, monitor.fex (BL31), scp.fex, and dts/. Pinned to the exact commit Armbian
  # pins, so the monitor/SCP blobs we pack are byte-identical to the ones in a working Armbian image (verified with sha256).
  orangepiBuild = pkgs.fetchFromGitHub {
    owner = "orangepi-xunlong";
    repo = "orangepi-build";
    rev = "7f776a209b72b92e8c6a06abc83b1e7597eef5af";
    hash = "sha256-T9wyQ01t4aLg/PUz9ssZ9KE1l5r8fDtGVaBQ6R1sdqc=";
  };

  # ---------------------------------------------------------------------------------------------------------------------------
  # The Allwinner packing tools are x86-only ELF binaries with no source. Run them under QEMU when we are not on x86_64.
  # ---------------------------------------------------------------------------------------------------------------------------
  # These are `update_dtb`, `update_uboot`, `script`, and `dragonsecboot`. They assemble the TOC1 container (boot_package.fex)
  # and stamp Allwinner's private header into the U-Boot binary. They are statically linked, so the QEMU wrapper only needs the
  # -L library path as a fallback; it works regardless.
  pkgsi686 = pkgs.pkgsCross.gnu32;
  pkgsx86_64 = pkgs.pkgsCross.gnu64;

  sunxiPackTools =
    pkgs.runCommand "sunxi-pack-tools"
      {
        nativeBuildInputs = [ pkgs.qemu ];
      }
      ''
        mkdir -p $out/bin
        # On x86_64 the tools run natively - no emulation needed.
        if [ "$(uname -m)" = "x86_64" ]; then
          echo "Running on x86_64, copying binaries natively..."
          for f in ${orangepiBuild}/external/packages/pack-uboot/tools/*; do
            if [ ! -f "$f" ]; then continue; fi
            fname=$(basename "$f")
            cp "$f" $out/bin/$fname
            chmod +x $out/bin/$fname
          done
        else
          echo "Running on $(uname -m), using QEMU..."
          X86_LIBS="${pkgsi686.glibc}/lib:${pkgsi686.stdenv.cc.cc.lib}/lib"
          X86_64_LIBS="${pkgsx86_64.glibc}/lib:${pkgsx86_64.stdenv.cc.cc.lib}/lib"
          for f in ${orangepiBuild}/external/packages/pack-uboot/tools/*; do
            if [ ! -f "$f" ]; then continue; fi
            fname=$(basename "$f")

            # Some entries in tools/ are data files, not ELF binaries - copy those through untouched.
            if file "$f" | grep -q "ELF"; then
              if file "$f" | grep -q "x86-64"; then
                QEMU_BIN="${pkgs.qemu}/bin/qemu-x86_64"
                LIB_PATH="$X86_64_LIBS"
              else
                QEMU_BIN="${pkgs.qemu}/bin/qemu-i386"
                LIB_PATH="$X86_LIBS"
              fi

              cat <<EOF > $out/bin/$fname
        #!/bin/sh
        exec $QEMU_BIN -L $LIB_PATH "$f" "\$@"
        EOF
              chmod +x $out/bin/$fname
            else
              cp "$f" $out/bin/$fname
              chmod +x $out/bin/$fname
            fi
          done
        fi
      '';

  # ---------------------------------------------------------------------------------------------------------------------------
  # Vendor U-Boot (32-bit ARM), built from source and packed into Allwinner's TOC1 container.
  # ---------------------------------------------------------------------------------------------------------------------------
  ubootOrangePi4Pro = pkgs.buildUBoot {
    version = "6.6-vendor";
    src = pkgs.fetchFromGitHub {
      owner = "orangepi-xunlong";
      repo = "u-boot-orangepi";
      rev = "v2018.05-sun60iw2";
      hash = "sha256-mR7u0eXr78lsL5G8JxgKYLNb5iTlfnoMj0aTrT8R01g=";
    };

    # This is the defconfig Orange Pi's own board recipe uses for the 4 Pro (BOOTCONFIG= in orangepi-build's
    # external/config/boards/orangepi4pro.conf), and the one Armbian inherits. Despite the "t736" (a devkit) name, this is the
    # correct, hardware-tested choice. The board's real identity - DRAM timing, pin muxing - does not come from this defconfig;
    # it comes from the board-specific boot0 and sys_config blobs packed in postBuild, and the Linux kernel gets the real board
    # DTB separately via hardware.deviceTree.
    defconfig = "sun60iw2p1_t736_defconfig";

    # The build's real outputs are not u-boot.bin but the two Allwinner images produced by postBuild's packing step.
    filesToInstall = [
      "boot0_sdcard.fex"
      "boot_package.fex"
    ];

    # Deliberately empty. nixpkgs whitespace-splits each element of `makeFlags`, so a flag with spaces in its value (like
    # KCFLAGS below) would be shredded into separate make arguments. Flags go through makeFlagsArray in preBuild instead.
    makeFlags = [ ];

    preBuild = ''
      # These are exactly the flags Armbian applies to this tree (post_config_uboot_target__sun60iw2_vendor_quirks).
      #
      # -fomit-frame-pointer is LOAD-BEARING. Do not remove it as a "cleanup".
      #   U-Boot's cleanup_before_linux_select() flushes the D-cache and then disables it. The vendor's own comment in that
      #   function states this is only safe because nothing is pushed onto the stack between the flush and the disable. A
      #   frame-pointer prologue (push {r7}; add r7, sp, #0) violates exactly that: it writes to the stack after the flush,
      #   those cache lines are dirty when the cache is disabled without writeback, and the popped return address comes back as
      #   garbage. The CPU then branches into nowhere and dies with "undefined instruction" at a wild pc, roughly 200 lines into
      #   the boot log, with no hint of the cause.
      #   Ubuntu's arm-linux-gnueabi-gcc (which Armbian uses) omits the frame pointer by default at -O2; every nixpkgs ARM
      #   cross-GCC keeps it. U-Boot itself only passes -fomit-frame-pointer to HOSTCFLAGS, never to the target build, so we
      #   must supply it. KCFLAGS is appended to KBUILD_CFLAGS (Makefile line ~736), which is the supported injection point.
      #
      # -fcommon reverses GCC >= 10's -fno-common default, which this 2018 code predates. The -Wno-* flags silence warnings that
      # this tree turns into errors under modern compilers.
      makeFlagsArray+=("KCFLAGS=-fcommon -fomit-frame-pointer -Wno-error -Wno-attributes -Wno-array-bounds -Wno-maybe-uninitialized -Wno-stringop-overflow")
    '';

    nativeBuildInputs = with pkgs; [
      bison
      flex
      swig
      python3
      bash
      tinyxxd # provides `xxd`, which the vendor Makefile uses to generate board/sunxi/sunxi_challenge.c
      git # the vendor Makefile calls `git describe` for the version string; postPatch creates a dummy repo for it
      bc
      perl
      findutils
      util-linux
      sunxiPackTools # puts update_dtb / update_uboot / script / dragonsecboot on PATH for postBuild
      pkgsArmLinuxGnueabi.buildPackages.gcc13
      pkgsArmLinuxGnueabi.buildPackages.binutils
      # The vendor Makefile unconditionally probes for a RISC-V toolchain (for other SoCs in the family that have a RISC-V
      # coprocessor). It is not used for this board, but its absence breaks the build, so provide one.
      pkgsCross.riscv64-embedded.buildPackages.gcc
      pkgsCross.riscv64-embedded.buildPackages.binutils
      # NOTE: `dtc` is deliberately NOT here. The build must use the tree's OWN dtc (rebuilt in postConfigure), not nixpkgs'.
    ];

    postConfigure = ''
      # Raise the autoboot countdown from the vendor default (2s) to 15s. This is a recovery/debugging affordance: 2 seconds is
      # very hard to catch on a serial console, and reaching the "=>" prompt is the only way to intervene if a boot script or
      # kernel is broken. Costs 13 seconds per boot; worth it on a board with no other recovery path.
      # (`./scripts/config` is a Linux-kernel helper that does not exist in U-Boot 2018, hence the .config fallback.)
      echo "Setting CONFIG_BOOTDELAY=15..."
      if [ -x ./scripts/config ]; then
        ./scripts/config --set-val BOOTDELAY 15
      else
        sed -i '/CONFIG_BOOTDELAY/d' .config
        echo "CONFIG_BOOTDELAY=15" >> .config
      fi
      make olddefconfig

      # The vendor tree COMMITS a prebuilt x86-only binary at scripts/dtc/dtc. On any non-x86 builder it cannot execute, and
      # Kbuild needs a working dtc to compile the control device tree that gets appended to u-boot.bin. Rebuild it from the
      # tree's own dtc source for the build platform - this is exactly what Armbian does in its family config.
      if ! ./scripts/dtc/dtc --version > /dev/null 2>&1; then
        echo "Rebuilding in-tree scripts/dtc for the build platform..."
        rm -f scripts/dtc/dtc
        make -f scripts/Makefile.build obj=scripts/dtc srctree=. objtree="$PWD" HOSTCC=cc HOSTCFLAGS="-O2 -fcommon" LEX=flex YACC=bison
        ./scripts/dtc/dtc --version
      fi
    '';

    postPatch = ''
      echo "Patching hardcoded paths and setting up hermetic toolchains..."
      patchShebangs scripts/
      if [ -f Makefile ]; then sed -i 's|/bin/bash|${pkgs.bash}/bin/bash|g' Makefile; fi

      # The vendor Makefile tries to untar toolchains it expects to find in ../tools/toolchain/. We supply the toolchains via
      # symlinks below instead, so delete the tar/mkdir lines that would fail in the sandbox.
      find . -name "Makefile" -o -name "*.mk" -o -name "config.mk" | xargs sed -i -E '/tar .*(toolchain|gcc-linaro|riscv64)/d' || true
      find . -name "Makefile" -o -name "*.mk" -o -name "config.mk" | xargs sed -i -E '/mkdir .*(toolchain|gcc-linaro|riscv64)/d' || true

      # The vendor Makefile HARDCODES CROSS_COMPILE to these exact paths (with `:=`, so it overrides anything we pass on the
      # command line). Rather than fight it, we materialize the directories it expects and point them at our Nix toolchains.
      # The ARM directory name mentions gcc-linaro 7.2.1, but the actual compiler behind the symlinks is our GCC 13 - only the
      # path is load-bearing, not the version.
      ARM32_BIN_DIR="../tools/toolchain/gcc-linaro-7.2.1-2017.11-x86_64_arm-linux-gnueabi/bin"
      RISCV_BIN_DIR="../tools/toolchain/riscv64-linux-x86_64-20200528/bin"
      mkdir -p "$ARM32_BIN_DIR" "$RISCV_BIN_DIR"
      for tool in gcc as ld ar nm objcopy objdump ranlib strip size readelf c++ g++ cpp; do
        real_tool=$(type -p armv7l-unknown-linux-gnueabi-$tool)
        if [ -n "$real_tool" ]; then ln -s "$real_tool" "$ARM32_BIN_DIR/arm-linux-gnueabi-$tool"; fi
      done
      # The RISC-V toolchain is probed but unused for this board; several prefix spellings are covered because different parts
      # of the vendor tree spell it differently.
      for tool in gcc as ld ar nm objcopy objdump ranlib strip size readelf; do
        real_tool=$(type -p riscv64-none-elf-$tool)
        if [ -n "$real_tool" ]; then
          for prefix in riscv64-unknown-linux-gnu- riscv64-unknown-elf- riscv64-linux-gnu- riscv64-none-elf-; do
            ln -s "$real_tool" "$RISCV_BIN_DIR/$prefix$tool" || true
          done
        fi
      done

      # scripts/sunxi_ubootools is another committed x86-only binary. The Makefile runs it on u-boot-nodtb.bin to stamp a
      # "dtb_offset" field into Allwinner's private header. Armbian's known-good binary has dtb_offset = 0 (verified by dumping
      # 0x4a0004f0 from a running board), i.e. the field is not needed to boot. Stubbing the tool out matches that reference
      # exactly and avoids emulating another proprietary binary. If you ever DO want it to run, it is dynamically linked (unlike
      # the pack tools), so a QEMU wrapper also needs patchelf to set its interpreter.
      cat << 'EOF' > scripts/sunxi_ubootools
      #!/usr/bin/env bash
      exit 0
      EOF
      chmod +x scripts/sunxi_ubootools
      patchShebangs scripts/sunxi_ubootools

      # The vendor Makefile calls `git describe` for the version banner; an empty repo satisfies it inside the Nix sandbox.
      git init -b main && git config user.name "Nix" && git config user.email "nix@local" && git commit --allow-empty -m "init"
    '';

    # Turn the compiled u-boot.bin into the two images boot0 and the BROM actually read from raw SD offsets. This mirrors
    # Armbian's uboot_custom_postprocess() step for step.
    postBuild = ''
      set -e
      echo "=== Packing U-Boot using Allwinner proprietary tools ==="

      # bin/ supplies the shared SoC boot assets: boot_package.cfg (the TOC1 manifest), monitor.fex (BL31), scp.fex, and dts/.
      mkdir -p pack_work
      cp -r ${orangepiBuild}/external/packages/pack-uboot/sun60iw2/bin/. ./pack_work/
      cd pack_work

      # Some revisions of the pack-uboot directory ship these as .bin; boot_package.cfg refers to them as .fex.
      if [ -f monitor.bin ] && [ ! -f monitor.fex ]; then cp monitor.bin monitor.fex; fi
      if [ -f scp.bin ] && [ ! -f scp.fex ]; then cp scp.bin scp.fex; fi

      # Our freshly compiled U-Boot becomes the "u-boot" item of the package.
      cp ../u-boot.bin u-boot.fex

      # Compile the SoC device tree with the tree's OWN dtc (rebuilt in postConfigure), then let update_dtb pad/fix it up.
      # This DTB is separate from the kernel's DTB; it configures U-Boot itself.
      ../scripts/dtc/dtc -p 2048 -W no-unit_address_vs_reg -@ -O dtb -o uboot.dtb -b 0 dts/u-boot-current.dts
      cp uboot.dtb sunxi.fex
      update_dtb sunxi.fex 4096

      # sys_config is Allwinner's board description (DRAM parameters, pin muxing, PMIC). It must be the OrangePi 4 Pro one -
      # Armbian's board file mandates a per-board blob and states there is no valid generic default. The proprietary `script`
      # tool compiles it to sys_config.bin, which update_uboot then stamps into U-Boot's header. That stamp is what sets the
      # `monitor_exist` byte U-Boot reads at runtime to decide whether to do the SMC handoff to BL31 (rather than an invalid
      # direct 32-bit jump into the 64-bit kernel). The tools require CRLF line endings.
      cp ${armbianBuild}/packages/blobs/sunxi/sun60iw2/sys_config_orangepi.fex sys_config.fex
      perl -pi -e 's/\r?\n/\r\n/' sys_config.fex
      export LC_ALL=C
      ${sunxiPackTools}/bin/script sys_config.fex

      update_uboot -no_merge u-boot.fex sys_config.bin

      # dragonsecboot assembles the final TOC1 container from boot_package.cfg: the u-boot, monitor, and scp items.
      sed -i 's/$/\r/' boot_package.cfg
      dragonsecboot -pack boot_package.cfg

      # boot0 is the DRAM-init blob the BROM loads. Board-specific: it carries this board's DRAM timings.
      cp ${armbianBuild}/packages/blobs/sunxi/sun60iw2/boot0_sdcard_orangepi4pro.fex ../boot0_sdcard.fex
      cp boot_package.fex ../boot_package.fex

      echo "--- Final Bootloader Sizes ---"
      ls -l ../boot0_sdcard.fex ../boot_package.fex
      cd ..
      echo "=== Packing complete! ==="
    '';
  };

  # ---------------------------------------------------------------------------------------------------------------------------
  # Vendor Linux kernel (aarch64, 6.6.98).
  # ---------------------------------------------------------------------------------------------------------------------------
  orangepiVendorKernel =
    (pkgs.linuxManualConfig {
      inherit (pkgs) stdenv;

      version = "6.6.98-sun60iw2";
      modDirVersion = "6.6.98";

      src = pkgs.fetchFromGitHub {
        owner = "orangepi-xunlong";
        repo = "linux-orangepi";
        rev = "orange-pi-6.6-sun60iw2"; # the vendor branch carrying A733/sun60iw2 support
        hash = "sha256-MfUDFi6Uu3NbZ06cfpzvo+vQfTWJGoZIdoRSlUnxz74=";
      };

      # Armbian's kernel config for this board - itself a verbatim copy of Orange Pi's own. Using a full config file (rather
      # than a `defconfig` make target) is what makes this tree build and boot; the in-tree defconfigs do not match the board.
      configfile = "${armbianBuild}/config/kernel/linux-sun60iw2-vendor.config";
      allowImportFromDerivation = true;

      # The four device-tree fixups Armbian carries on top of the vendor tree for this specific board: correct model string,
      # disable the unpopulated UFS controller, disable the absent AXP515 battery-management chip, and disable the unpopulated
      # AC101 audio codec. Without these the kernel probes hardware that is not on the board.
      kernelPatches =
        map
          (n: {
            name = n;
            patch = "${armbianBuild}/patch/kernel/archive/sun60iw2-opi-vendor/${n}";
          })
          [
            "0001-orangepi4pro-set-model-string.patch"
            "0002-orangepi4pro-disable-unused-ufs.patch"
            "0003-orangepi4pro-disable-axp515-bmu.patch"
            "0004-orangepi4pro-disable-unpopulated-ac101-audio.patch"
          ];
      extraMeta.branch = "6.6";
    }).overrideAttrs
      (old: {
        enableParallelBuilding = true;

        postPatch = (old.postPatch or "") + /* bash */ ''
          # The vendor's out-of-tree bsp/ directory uses `include $(src)/...`, which only resolves when building in-tree.
          # Rewrite to $(srctree)/$(src)/ so it also works from a separate build directory (which Nix always uses).
          find bsp/ -name Makefile -exec sed -i 's|include[[:space:]]\+\$(src)/|include \$(srctree)/\$(src)/|g' {} +

          # The vendor DTS declares memory@40000000 with a 32-bit-style reg property that understates RAM. Rewrite it to the
          # 64-bit cell format describing the real 4 GiB (base 0x40000000, size 0x1_00000000). Without this the kernel sees the
          # wrong amount of memory.
          find arch/arm64/boot/dts/allwinner/ -name "*.dts" -o -name "*.dtsi" | xargs perl -0777 -pi -e 's/(memory\@40000000\s*\{[^}]*?reg\s*=\s*)<[^>]+>;/\1<0x0 0x40000000 0x1 0x00000000>;/gs'
        '';

        nativeBuildInputs =
          with pkgs;
          [
            # GNU Make 4.4 changed how it handles some constructs this 2023-era vendor tree relies on; 4.2 builds it cleanly.
            # It must come first in PATH, hence prepending rather than appending.
            gnumake42
            ubootTools
            lz4
            zstd
            perl
            findutils
          ]
          ++ (old.nativeBuildInputs or [ ]);
      });

  # ---------------------------------------------------------------------------------------------------------------------------
  # boot.scr - the U-Boot script baked into the SD image (the image-build-time twin of installOpi4ProBootloader).
  # ---------------------------------------------------------------------------------------------------------------------------
  # The vendor U-Boot's distro-boot logic scans partitions for /boot/boot.scr and sources it. This is where we take control of
  # the memory map, which is the single most fragile part of this port.
  bootScript = pkgs.runCommand "boot.scr" { nativeBuildInputs = [ pkgs.ubootTools ]; } (
    let
      # No `root=`: see the note in installOpi4ProBootloader. The initrd's own fstab is the authoritative source, and passing
      # root= as well makes systemd stage 1 generate sysroot.mount twice and abort.
      bootArgs = "init=${config.system.build.toplevel}/init ${toString config.boot.kernelParams}";
    in
    /* bash */ ''
      cat << EOF > boot.cmd
      # Armbian's hardware-tested sun60iw2 memory map. BL31 (the secure monitor) is RESIDENT at 0x48000000-0x48ffffff and is
      # still needed at handoff time - U-Boot calls into it via SMC to switch the CPU to 64-bit and enter the kernel. So the
      # kernel goes BELOW it and the FDT/initrd go ABOVE it.
      setenv kernel_addr_r 0x41000000
      setenv fdt_addr_r 0x4a000000
      setenv ramdisk_addr_r 0x4b000000

      # fdt_high/initrd_high = 0xffffffff means "do not relocate, use in place". This is essential, not cosmetic: by default
      # U-Boot relocates the initrd to the top of its bootm pool (bootm_size=0xa000000, so the top is 0x4a000000). A 38 MB
      # NixOS initrd relocated there lands at ~0x479db000-0x49fff2b5 - directly on top of resident BL31, destroying the monitor
      # seconds before the SMC that needs it. The board then hangs silently right after "Starting kernel ...".
      setenv fdt_high 0xffffffff
      setenv initrd_high 0xffffffff

      load mmc 0:1 \$ramdisk_addr_r uInitrd
      load mmc 0:1 \$kernel_addr_r Image
      load mmc 0:1 \$fdt_addr_r allwinner/sun60i-a733-orangepi-4-pro.dtb

      # Grow the FDT so U-Boot can inject the /chosen node (bootargs, initrd start/end) without running out of space.
      fdt addr \$fdt_addr_r
      fdt resize 65536

      setenv bootargs "${bootArgs}"
      # booti = boot a raw aarch64 Image. (bootm would demand a legacy uImage wrapper and reject a 64-bit payload outright on
      # this 32-bit U-Boot; the vendor's SMC handoff to BL31 is what actually enters the kernel.)
      booti \$kernel_addr_r \$ramdisk_addr_r \$fdt_addr_r
      EOF
      mkimage -C none -A arm -T script -d boot.cmd boot.scr
      cp boot.scr $out
    ''
  );

  # The initrd, wrapped in U-Boot's legacy image format. -C gzip must match boot.initrd.compressor below: the wrapper only
  # records which compression was used, so a mismatch means U-Boot hands the kernel a ramdisk it cannot unpack.
  initrdUImage = pkgs.runCommand "uInitrd" { nativeBuildInputs = [ pkgs.ubootTools ]; } /* bash */ ''
    mkdir -p "$out"
    ${pkgs.ubootTools}/bin/mkimage -A arm -O linux -T ramdisk -C gzip -n "uInitrd" -d "${config.system.build.initialRamdisk}/initrd" "$out/uInitrd"
    echo "Verifying uInitrd..."
    ${pkgs.ubootTools}/bin/mkimage -l "$out/uInitrd"
  '';
in
{
  imports = [
    "${modulesPath}/profiles/base.nix"
    "${modulesPath}/installer/sd-card/sd-image.nix"
  ];

  hardware = {
    wirelessRegulatoryDatabase = true;
    deviceTree = {
      enable = true;
      name = "allwinner/sun60i-a733-orangepi-4-pro.dtb";
    };
    enableRedistributableFirmware = true;
  };

  boot = {
    kernelPackages = pkgs.linuxPackagesFor orangepiVendorKernel;
    kernelParams = [
      "console=ttyS0,115200n8"
      "console=tty0"
      # earlyprintk (not earlycon) is what Armbian uses with this exact vendor kernel; it produces output from the very first
      # kernel instructions, before the real serial driver is up.
      "earlyprintk=sunxi-uart,0x02500000"
      "panic=10"
      # The vendor kernel's clock driver disables "unused" clocks that some of its own drivers still depend on.
      "clk_ignore_unused"
    ];
    initrd = {
      # Must be gzip: the uInitrd wrapper above is tagged -C gzip, and U-Boot's legacy ramdisk format has no way to negotiate.
      compressor = "gzip";
      # The vendor kernel is monolithic for the drivers we need at stage 1; forcing an empty module list avoids the initrd trying
      # to load modules that do not exist in this tree.
      kernelModules = lib.mkForce [ ];
      availableKernelModules = lib.mkForce [
        "mmc_block"
        "ext4"
        "ext2"
        "vfat"
        "nls_cp437"
        "nls_iso8859-1"
        "uas"
        "usb_storage"
        "nvme"
        "fuse"
      ];
    };
    consoleLogLevel = 7; # verbose kernel output on the serial console; this board has no other diagnostic channel

    loader = {
      # extlinux would fight us for control of the boot files and expects a memory map this board cannot use (see boot.scr above).
      # We drive the boot entirely from boot.scr instead.
      generic-extlinux-compatible.enable = lib.mkForce false;
      grub.enable = false;

      # Makes `nixos-rebuild switch` update the kernel/initrd/DTB on the FAT partition and regenerate /boot/boot.scr.
      external = {
        enable = true;
        installHook = installOpi4ProBootloader;
      };
    };
    zfs.forceImportRoot = false;
  };

  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";

  sdImage = {
    # The sd-image module would normally write an extlinux config here. We replace that with our boot.scr, at the path the vendor
    # U-Boot's distro-boot scan looks for it: /boot/boot.scr on the ext4 root partition (mmc 0:2).
    populateRootCommands = /* bash */ ''
      mkdir -p ./files/boot/firmware
      cp -v ${bootScript} ./files/boot/boot.scr
    '';

    # The FAT firmware partition (mmc 0:1) holds what boot.scr loads: the raw kernel Image, the wrapped uInitrd, and the DTB.
    populateFirmwareCommands = /* bash */ ''
      FWDIR="''${FWDIR:-$(pwd)/firmware}"
      mkdir -p "$FWDIR"
      cp -v "${config.boot.kernelPackages.kernel}/Image" "$FWDIR/Image"
      cp -v ${initrdUImage}/uInitrd "$FWDIR/uInitrd"
      install -D -m 644 "${config.boot.kernelPackages.kernel}/dtbs/${config.hardware.deviceTree.name}" "$FWDIR/allwinner/sun60i-a733-orangepi-4-pro.dtb"
    '';

    # Write the bootloader to the raw sectors the BROM and boot0 read from. These offsets are fixed by the hardware/blob contract,
    # not by us: boot0 at 8 KiB, boot_package at 16400 KiB. (Armbian's write_uboot_platform() uses exactly the same two offsets.)
    #
    # RECOVERY: if a bad U-Boot ever leaves the board unbootable, you can restore a known-good bootloader without rebuilding, by
    # extracting boot0_sdcard.fex and boot_package.fex from /usr/lib/linux-u-boot-*/ inside an official Armbian image and dd'ing
    # them to the same two offsets on the card.
    postBuildCommands = /* bash */ ''
      echo "Flashing locally built Allwinner boot0 and boot_package..."
      dd if=${ubootOrangePi4Pro}/boot0_sdcard.fex of=$img seek=8 conv=notrunc bs=1k
      dd if=${ubootOrangePi4Pro}/boot_package.fex of=$img seek=16400 conv=notrunc bs=1k
    '';

    firmwareSize = 256;
    # 48 MiB. The FAT partition MUST start after the bootloader region: boot_package.fex is written at 16400 KiB (16.4 MiB) and is
    # ~1.4 MB. The sd-image default of 8 MiB puts the filesystem directly under it, so the dd above silently corrupts whatever
    # file happens to live there - which first showed up as a "Bad Data CRC" on the kernel image.
    firmwarePartitionOffset = 48;
  };

  # Mounted so the install hook can update the kernel/initrd/DTB on every `nixos-rebuild switch`. nofail keeps a missing or
  # damaged FAT partition from blocking multi-user boot (you would still get a shell to fix it from).
  fileSystems."/boot/firmware" = {
    device = "/dev/disk/by-label/FIRMWARE";
    fsType = "vfat";
    options = [
      "nofail"
      "auto"
      "umask=0077"
    ];
  };

  # Allows caching, run, for example:
  # nix build .#nixosConfigurations.opi4pro.config.system.build.opi4proInitrdUImage --no-link --print-out-paths | attic push servers --stdin
  system.build = {
    # Exposes the bootloader on its own so it can be built and flashed without regenerating the whole SD image:
    #   nix build .#nixosConfigurations.opi4pro.config.system.build.opi4proUboot --print-build-logs
    #   sudo dd if=result/boot_package.fex of=/dev/sdX bs=1k seek=16400 conv=notrunc,fsync
    opi4proUboot = ubootOrangePi4Pro;
    opi4proInitrdUImage = initrdUImage;
  };
}
