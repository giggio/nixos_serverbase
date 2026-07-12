{
  lib,
  modulesPath,
  pkgs,
  config,
  ...
}:

let
  installOpi4ProBootloader = pkgs.writeShellScript "install-opi4pro-bootloader" ''
    set -euo pipefail
    toplevel="$1"
    fw=/boot/firmware

    if ! ${pkgs.util-linux}/bin/mountpoint -q "$fw"; then
      echo "ERROR: $fw is not mounted; refusing to install bootloader files" >&2
      exit 1
    fi

    echo "opi4pro: installing kernel, initrd, dtb to $fw"
    cp "$toplevel/kernel" "$fw/Image.new" && mv "$fw/Image.new" "$fw/Image"

    ${pkgs.ubootTools}/bin/mkimage -A arm -O linux -T ramdisk -C gzip -n uInitrd -d "$toplevel/initrd" "$fw/uInitrd.new"
    mv "$fw/uInitrd.new" "$fw/uInitrd"

    mkdir -p "$fw/allwinner"
    cp "$toplevel/dtbs/allwinner/sun60i-a733-orangepi-4-pro.dtb" "$fw/allwinner/.dtb.new"
    mv "$fw/allwinner/.dtb.new" "$fw/allwinner/sun60i-a733-orangepi-4-pro.dtb"

    echo "opi4pro: regenerating /boot/boot.scr for $toplevel"
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

  # gccLinaroArm = pkgs.stdenvNoCC.mkDerivation {
  #   pname = "gcc-linaro-arm-linux-gnueabi-bin";
  #   version = "7.2.1-2017.11";
  #   src = pkgs.fetchurl {
  #     url = "https://developer.arm.com/-/cdn-downloads/permalink/legacy-linaro-gnu-toolchains/7.2-2017.11/gcc-linaro-7.2.1-2017.11-x86_64_arm-linux-gnueabi.tar.xz";
  #     hash = "sha256-iem/x//mFfQKcsJJLfBIjyX8IEBOX0dFAcjVWUEzf3E=";
  #   };
  #   nativeBuildInputs = [
  #     pkgs.autoPatchelfHook
  #     # pkgs.patchelf
  #   ];
  #   buildInputs = with pkgs; [
  #     stdenv.cc.cc.lib
  #     zlib
  #     expat
  #     # glibc # This ensures glibc stays in the store after the build
  #   ];
  #   autoPatchelfIgnoreMissingDeps = true;
  #   installPhase = ''
  #     mkdir -p $out
  #     cp -a . $out
  #     rm -f $out/bin/*gdb* # gdb needs python2/ncurses5; we don't need gdb
  #   '';
  #   # CRITICAL FIX: Explicitly patch the interpreter and RPATH.
  #   # autoPatchelfHook is failing to rewrite the hardcoded /lib64/ld-linux-x86-64.so.2 interpreter path, which causes "required file not found" in the Nix sandbox.
  #   # Failing with skipping /nix/store/9ih643dqqjqwd3irf1bi3xi6pfb3hdci-gcc-linaro-arm-linux-gnueabi-bin-7.2.1-2017.11/bin/arm-linux-gnueabi-gcc because its architecture (x64) differs from target (AArch64)
  #   # postFixup = ''
  #   #   echo "Explicitly patching Linaro toolchain binaries..."
  #   #   # The dynamic linker on NixOS x86_64 lives in lib64/, not lib/
  #   #   INTERP="${pkgs.glibc}/lib64/ld-linux-x86-64.so.2"
  #   #   echo "Setting interpreter to: $INTERP"
  #   #   for bin in $out/bin/*; do
  #   #     if [ -f "$bin" ] && [ -x "$bin" ]; then
  #   #       # 1. Force the interpreter to the correct Nix store path
  #   #       patchelf --set-interpreter "$INTERP" "$bin" || echo "Could not patch to set interpreter of $bin"
  #   #       # 2. Add all possible library paths to RPATH
  #   #       patchelf --set-rpath "$out/lib:$out/lib64:$out/arm-linux-gnueabi/lib:$out/lib/gcc/arm-linux-gnueabi/7.2.1" "$bin" || echo "Could not patch elf to set rpath to $out/lib:$out/lib64:$out/arm-linux-gnueabi/lib:$out/lib/gcc/arm-linux-gnueabi/7.2.1"
  #   #     fi
  #   #   done
  #   # '';
  #   dontStrip = true;
  # };

  # Pin to the Armbian tag that carries the merged, hardware-tested
  # Orange Pi 4 Pro support (armbian/build#9967 and follow-ups).
  armbianBuild = pkgs.fetchFromGitHub {
    owner = "armbian";
    repo = "build";
    rev = "v26.8.0-trunk.343";
    hash = "sha256-/3Jl3xTsLiDmUWCBwPORB1pRkLFKz83/8MaEEtRbYXA=";
  };

  # Fetch the Orange Pi build repo to get the proprietary packing tools and boot0 blobs
  orangepiBuild = pkgs.fetchFromGitHub {
    owner = "orangepi-xunlong";
    repo = "orangepi-build";
    rev = "7f776a209b72b92e8c6a06abc83b1e7597eef5af"; # The exact commit Armbian uses
    hash = "sha256-T9wyQ01t4aLg/PUz9ssZ9KE1l5r8fDtGVaBQ6R1sdqc=";
  };

  # Create package sets for x86 and x86_64 to get their glibc libraries.
  pkgsi686 = pkgs.pkgsCross.gnu32;
  pkgsx86_64 = pkgs.pkgsCross.gnu64;

  # Wrap the proprietary x86 packing tools in QEMU (only if not on x86_64)
  sunxiPackTools =
    pkgs.runCommand "sunxi-pack-tools"
      {
        nativeBuildInputs = [ pkgs.qemu ];
      }
      ''
        mkdir -p $out/bin
        # If we are on x86_64, just copy the binaries natively! No QEMU needed.
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

  ubootOrangePi4Pro = pkgs.buildUBoot {
    version = "6.6-vendor";
    src = pkgs.fetchFromGitHub {
      owner = "orangepi-xunlong";
      repo = "u-boot-orangepi";
      rev = "v2018.05-sun60iw2";
      hash = "sha256-mR7u0eXr78lsL5G8JxgKYLNb5iTlfnoMj0aTrT8R01g=";
    };
    # IMPORTANT: Armbian's actual, hardware-tested sun60iw2 family recipe
    # (config/sources/families/sun60iw2.conf, BOOTCONFIG=) builds U-Boot
    # itself against the generic T736 devkit defconfig, NOT the a733/OrangePi
    # one. Diffing the two confirms they disagree on CONFIG_SUNXI_TEXT_SIZE
    # (0x150000 vs 0x180000), USB VBUS pin muxing, and several driver
    # selections (SPI-NOR, PCIe, hwspinlock). U-Boot proper's own
    # CONFIG_DEFAULT_DEVICE_TREE doesn't need to match the real board here -
    # board identity/DRAM timing/pinmux come from the boot0 and sys_config
    # blobs (already board-specific below), and the Linux kernel gets the
    # real board DTB separately via hardware.deviceTree. Using the
    # "orangepi-4-pro" defconfig here is what was producing a U-Boot binary
    # ATF/BL31 couldn't hand a DTB to ("No DTB found" / opteed_fast init
    # failure at boot).
    defconfig = "sun60iw2p1_t736_defconfig";

    # We output the Allwinner .fex files generated by the packing tools
    filesToInstall = [
      "boot0_sdcard.fex"
      "boot_package.fex"
    ];

    makeFlags = [
      "SCP=/dev/null"
      "KCFLAGS=-w -Wno-error"
      "DTC=dtc"
    ];

    nativeBuildInputs = with pkgs; [
      bison
      flex
      swig
      python3
      bash
      tinyxxd
      git
      dtc
      bc
      perl
      findutils
      util-linux
      sunxiPackTools # Injects the QEMU-wrapped packing tools into PATH
      pkgsCross.arm-embedded.buildPackages.gcc
      pkgsCross.arm-embedded.buildPackages.binutils
      pkgsCross.riscv64-embedded.buildPackages.gcc
      pkgsCross.riscv64-embedded.buildPackages.binutils
    ];

    postConfigure = ''
      # DEBUG AID: give ourselves a wide, unmissable window to interrupt autoboot.
      # The default (2s) collapses to one line in a plain-text serial capture
      # (via \r overwrites) and is trivially easy to miss.
      echo "Setting CONFIG_BOOTDELAY=15 for debugging..."
      if [ -x ./scripts/config ]; then
        ./scripts/config --set-val BOOTDELAY 15
      else
        sed -i '/CONFIG_BOOTDELAY/d' .config
        echo "CONFIG_BOOTDELAY=15" >> .config
      fi
      make olddefconfig
    '';

    postPatch = ''
      echo "Patching hardcoded paths and setting up hermetic toolchains..."
      patchShebangs scripts/
      if [ -f Makefile ]; then sed -i 's|/bin/bash|${pkgs.bash}/bin/bash|g' Makefile; fi
      find . -name "Makefile" -o -name "*.mk" -o -name "config.mk" | xargs sed -i -E '/tar .*(toolchain|gcc-linaro|riscv64)/d' || true
      find . -name "Makefile" -o -name "*.mk" -o -name "config.mk" | xargs sed -i -E '/mkdir .*(toolchain|gcc-linaro|riscv64)/d' || true

      # FIX 1: Fix vendor typo
      if [ -f arch/arm/include/asm/arch/pmic_bus.h ]; then
        sed -i 's/_SUNXI_PMIS_BUS_H/_SUNXI_PMIC_BUS_H/g' arch/arm/include/asm/arch/pmic_bus.h
      fi

      # FIX 2: Prevent 'unreachable' macro collision
      if [ -f include/linux/compiler-gcc.h ]; then
        sed -i '/#define unreachable()/i #undef unreachable' include/linux/compiler-gcc.h
      fi

      # FIX 3: Strip -Werror
      find . -name "Makefile" -o -name "*.mk" | xargs sed -i 's/-Werror//g' || true

      # FIX 4: Stub out vblk.c to satisfy the linker for the t736 defconfig.
      if [ -f drivers/block/vblk.c ]; then
        echo "Stubbing out drivers/block/vblk.c to support legacy block mode..."
        cat << 'EOF' > drivers/block/vblk.c
      /* Dummy file to satisfy legacy build rules and linker */
      int vblk_create() {
          return 0;
      }
      int vblk_get_devnum_by_typename(const char *ifname) {
          return -1; // Return -1 to indicate no virtual block devices found
      }
      int vblk_init(void) {
          return 0;
      }
      EOF
      fi

      # FIX 5: Robustly remove ALL problematic stdint.h inclusions from the ENTIRE tree
      find . -type f \( -name "*.c" -o -name "*.h" \) -exec sed -i '/#include.*stdint\.h/d' {} +

      # FIX 6: (Now inert with defconfig=sun60iw2p1_t736_defconfig, which targets
      # "sun60iw2p1-soc-system" instead - left in place since it's harmless and
      # makes it easy to switch defconfigs back for comparison/debugging.)
      # The vendor tree expects a root DTS file, but board-uboot.dts is just a fragment.
      # We must create a root DTS file that includes the SoC definitions and the board fragment.
      if [ ! -f arch/arm/dts/sun60iw2p1-orangepi-4-pro.dts ]; then
        echo "Creating root DTS wrapper for Orange Pi 4 Pro..."
        cat << 'DTS_EOF' > arch/arm/dts/sun60iw2p1-orangepi-4-pro.dts
      /dts-v1/;

      #include "sun60iw2p1-soc-system.dts"
      #include "board-uboot.dts"

      / {
          model = "OrangePi 4 Pro";
          compatible = "xunlong,orangepi-4-pro", "allwinner,sun60iw2";
      };
      DTS_EOF
      fi

      # FIX 7: Dummy script for sunxi_ubootools
      cat << 'EOF' > scripts/sunxi_ubootools
      #!/usr/bin/env bash
      exit 0
      EOF
      chmod +x scripts/sunxi_ubootools
      patchShebangs scripts/sunxi_ubootools


      # Construct toolchain paths
      ARM32_BIN_DIR="../tools/toolchain/gcc-linaro-7.2.1-2017.11-x86_64_arm-linux-gnueabi/bin"
      RISCV_BIN_DIR="../tools/toolchain/riscv64-linux-x86_64-20200528/bin"
      mkdir -p "$ARM32_BIN_DIR" "$RISCV_BIN_DIR"

      # CRITICAL: Include readelf and other tools in the wrapper loop!
      for tool in gcc as ld ar nm objcopy objdump ranlib strip size readelf c++ g++ cpp; do
        real_tool=$(type -p arm-none-eabi-$tool)
        if [ -n "$real_tool" ]; then ln -s "$real_tool" "$ARM32_BIN_DIR/arm-linux-gnueabi-$tool"; fi
      done
      for tool in gcc as ld ar nm objcopy objdump ranlib strip size readelf; do
        real_tool=$(type -p riscv64-none-elf-$tool)
        if [ -n "$real_tool" ]; then
          for prefix in riscv64-unknown-linux-gnu- riscv64-unknown-elf- riscv64-linux-gnu- riscv64-none-elf-; do
            ln -s "$real_tool" "$RISCV_BIN_DIR$prefix$tool" || true
          done
        fi
      done

      git init -b main && git config user.name "Nix" && git config user.email "nix@local" && git commit --allow-empty -m "init"
    '';

    postBuild = ''
      set -e
      echo "=== Packing U-Boot using Allwinner proprietary tools ==="

      mkdir -p pack_work
      cp -r ${orangepiBuild}/external/packages/pack-uboot/sun60iw2/bin/. ./pack_work/
      cd pack_work

      # CRITICAL FIX: boot_package.cfg expects monitor.fex and scp.fex.
      # The bin directory provides monitor.bin and scp.bin. We must rename them!
      if [ -f monitor.bin ]; then
        echo "Copying monitor.bin to monitor.fex..."
        cp monitor.bin monitor.fex
      else
        echo "WARNING: monitor.bin not found in pack-uboot bin directory!"
      fi

      if [ -f scp.bin ]; then
        echo "Copying scp.bin to scp.fex..."
        cp scp.bin scp.fex
      else
        echo "WARNING: scp.bin not found in pack-uboot bin directory!"
      fi

      # DEBUG: List files to ensure everything is present before packing
      echo "--- Contents of pack_work before packing ---"
      ls -l
      echo "--------------------------------------------"

      # Prepare u-boot.fex
      cp ../u-boot.bin u-boot.fex

      # Compile DTB
      dtc -p 2048 -W no-unit_address_vs_reg -@ -O dtb -o uboot.dtb -b 0 dts/u-boot-current.dts
      cp uboot.dtb sunxi.fex

      echo "Running update_dtb..."
      update_dtb sunxi.fex 4096
      echo "update_dtb finished. Size of sunxi.fex: $(stat -c%s sunxi.fex)"

      echo "Generating sys_config.bin using the vendor's own paired sys_config.fex..."
      # Board-specific sys_config: Armbian's board file mandates per-board
      # DRAM/pinmux blobs; there is no valid generic default.
      cp ${armbianBuild}/packages/blobs/sunxi/sun60iw2/sys_config_orangepi.fex sys_config.fex
      perl -pi -e 's/\r?\n/\r\n/' sys_config.fex
      export LC_ALL=C
      ${sunxiPackTools}/bin/script sys_config.fex
      echo "script finished. Size of sys_config.bin: $(stat -c%s sys_config.bin)"
      echo "--- DEBUG: Checking sys_config.bin ---"
      ls -l sys_config.bin
      hexdump -C sys_config.bin | head -n 5 || true
      echo "--------------------------------------"

      echo "Running update_uboot (stamping the packaged copy)..."
      update_uboot -no_merge u-boot.fex sys_config.bin
      echo "update_uboot finished. Size of u-boot.fex: $(stat -c%s u-boot.fex)"
      # HYBRID TEST: overwrite our stamped u-boot with Armbian's packed item,
      # which already carries THEIR stamp — must come AFTER update_uboot so
      # nothing of ours touches it. Delete this line once the bisect is done.
      cp ${./blobs/armbian-uboot-item.fex} u-boot.fex

      # DEBUG: Print boot_package.cfg
      echo "--- boot_package.cfg contents ---"
      cat boot_package.cfg
      echo "---------------------------------"

      sed -i 's/$/\r/' boot_package.cfg
      echo "Running dragonsecboot..."
      dragonsecboot -pack boot_package.cfg

      # CRITICAL FIX: use the vendor's own generic A733 boot0 blob. There is no "orangepi4pro"-specific boot0 in the real vendor tree — Armbian's file of
      # that name is a repackaging, not confirmed identical. orangepi-build's own board recipe falls back to exactly this file for this exact board:
      #   cp "$BIN_PATH/boot0_sdcard_$BOARD.fex" ./boot0_sdcard.fex 2>/dev/null || cp "$BIN_PATH/boot0_sdcard_a733.fex" ./boot0_sdcard.fex
      cp ${armbianBuild}/packages/blobs/sunxi/sun60iw2/boot0_sdcard_orangepi4pro.fex ../boot0_sdcard.fex
      cp boot_package.fex ../boot_package.fex

      echo "--- Final Bootloader Sizes ---"
      ls -l ../boot0_sdcard.fex ../boot_package.fex
      echo "------------------------------"

      cd ..
      set +x
      echo "=== Packing complete! ==="
    '';
  };

  orangepiVendorKernel =
    (pkgs.linuxManualConfig {
      inherit (pkgs) stdenv;

      version = "6.6.98-sun60iw2";
      modDirVersion = "6.6.98";

      src = pkgs.fetchFromGitHub {
        owner = "orangepi-xunlong";
        repo = "linux-orangepi";
        rev = "orange-pi-6.6-sun60iw2"; # The specific branch for the A733 SoC
        hash = "sha256-MfUDFi6Uu3NbZ06cfpzvo+vQfTWJGoZIdoRSlUnxz74=";
      };

      # The actual working config Armbian ships for this board — a verbatim
      # copy of Orange Pi's own orangepi-build config. Using this instead of
      # a bare `defconfig` target is almost certainly what fixes your loop.
      configfile = "${armbianBuild}/config/kernel/linux-sun60iw2-vendor.config";
      allowImportFromDerivation = true;

      # The four DT fixups Armbian carries on top of the vendor tree.
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

        # CRITICAL FIX: Fixes the vendor out-of-tree compilation bug
        postPatch = (old.postPatch or "") + /* bash */ ''
          find bsp/ -name Makefile -exec sed -i 's|include[[:space:]]\+\$(src)/|include \$(srctree)/\$(src)/|g' {} +
          # CRITICAL FIX: Hardcode the correct RAM size in the 64-bit DTB format.
          find arch/arm64/boot/dts/allwinner/ -name "*.dts" -o -name "*.dtsi" | xargs perl -0777 -pi -e 's/(memory\@40000000\s*\{[^}]*?reg\s*=\s*)<[^>]+>;/\1<0x0 0x40000000 0x1 0x00000000>;/gs'
        '';
        # 2. Prepend gnumake42 to guarantee priority, and add vital ARM image utilities
        nativeBuildInputs =
          with pkgs;
          [
            gnumake42
            ubootTools # Provides 'mkimage' if the vendor tree builds a uImage format
            lz4 # Common compression tools used by modern ARM kernels
            zstd
            perl
            findutils
          ]
          ++ (old.nativeBuildInputs or [ ]);
      });

  bootScript = pkgs.runCommand "boot.scr" { nativeBuildInputs = [ pkgs.ubootTools ]; } (
    let
      bootArgs = "init=${config.system.build.toplevel}/init ${toString config.boot.kernelParams}";
    in
    /* bash */ ''
      cat << EOF > boot.cmd
      # Armbian's hardware-tested sun60iw2 map: kernel below BL31 (0x48000000),
      # FDT + initrd above it. fdt_high/initrd_high pin both IN PLACE — without
      # them U-Boot relocates the initrd to the top of the bootm pool, which for
      # any initrd larger than ~16MB lands directly on top of resident BL31.
      setenv kernel_addr_r 0x41000000
      setenv fdt_addr_r 0x4a000000
      setenv ramdisk_addr_r 0x4b000000
      setenv fdt_high 0xffffffff
      setenv initrd_high 0xffffffff

      load mmc 0:1 \$ramdisk_addr_r uInitrd
      load mmc 0:1 \$kernel_addr_r Image
      load mmc 0:1 \$fdt_addr_r allwinner/sun60i-a733-orangepi-4-pro.dtb

      # Resize FDT to make room for /chosen node and bootargs
      fdt addr \$fdt_addr_r
      fdt resize 65536

      setenv bootargs "${bootArgs}"
      # Use booti with raw Image
      booti \$kernel_addr_r \$ramdisk_addr_r \$fdt_addr_r
      EOF
      mkimage -C none -A arm -T script -d boot.cmd boot.scr
      cp boot.scr $out
    ''
  );

  # Create the initrd uImage in a separate derivation
  initrdUImage = pkgs.runCommand "uInitrd" { nativeBuildInputs = [ pkgs.ubootTools ]; } /* bash */ ''
    mkdir -p "$out"
    # Create the uInitrd with proper CRC
    ${pkgs.ubootTools}/bin/mkimage -A arm -O linux -T ramdisk -C gzip -n "uInitrd" -d "${config.system.build.initialRamdisk}/initrd" "$out/uInitrd"
    # Verify the uInitrd was created correctly
    echo "Verifying uInitrd..."
    ${pkgs.ubootTools}/bin/mkimage -l "$out/uInitrd"
  '';
in
{
  imports = [
    "${modulesPath}/profiles/base.nix"
    "${modulesPath}/installer/sd-card/sd-image.nix"
  ];

  boot.kernelPackages = pkgs.linuxPackagesFor orangepiVendorKernel;
  boot.consoleLogLevel = 7;
  boot.kernelParams = [
    "console=ttyS0,115200n8"
    "console=tty0"
    # "earlycon=uart8250,mmio32,0x02500000"
    "earlyprintk=sunxi-uart,0x02500000"
    "panic=10"
    "clk_ignore_unused"
  ];

  hardware.wirelessRegulatoryDatabase = true;
  hardware.deviceTree = {
    enable = true;
    name = "allwinner/sun60i-a733-orangepi-4-pro.dtb";
  };

  boot.initrd = {
    compressor = "gzip"; # CRITICAL: Force gzip compression so U-Boot's legacy uImage format can handle it
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

  boot.loader.generic-extlinux-compatible.enable = lib.mkForce false; # CRITICAL: Disable extlinux completely. We are using boot.scr instead!
  boot.loader.grub.enable = false;
  boot.loader.external = {
    enable = true;
    installHook = installOpi4ProBootloader;
  };
  hardware.enableRedistributableFirmware = true;
  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
  boot.zfs.forceImportRoot = false;

  # CRITICAL FIX: Override populateRootCommands to bypass the extlinux dependency.
  # This places boot.scr exactly where the vendor U-Boot expects it: /boot/boot.scr on the rootfs (mmc 0:2)
  sdImage.populateRootCommands = /* bash */ ''
    mkdir -p ./files/boot
    cp -v ${bootScript} ./files/boot/boot.scr
  '';

  # Create a FAT firmware partition with the necessary boot files
  sdImage.populateFirmwareCommands = /* bash */ ''
    FWDIR="''${FWDIR:-$(pwd)/firmware}"
    mkdir -p "$FWDIR"
    # Use raw Image (no uImage wrapping)
    cp -v "${config.boot.kernelPackages.kernel}/Image" "$FWDIR/Image"
    # Keep uInitrd wrapping
    cp -v ${initrdUImage}/uInitrd "$FWDIR/uInitrd"
    # Copy DTB
    install -D -m 644 "${config.boot.kernelPackages.kernel}/dtbs/${config.hardware.deviceTree.name}" "$FWDIR/allwinner/sun60i-a733-orangepi-4-pro.dtb"
  '';

  # Flash the Allwinner bootloader to raw disk sectors
  # sdImage.postBuildCommands = /* bash */ ''
  #   echo "Flashing Allwinner boot0 and boot_package to the raw SD card..."
  #   # boot0 initializes DRAM (Offset: 8KB)
  #   dd if=${ubootOrangePi4Pro}/boot0_sdcard.fex of=$img seek=8 conv=notrunc bs=1k
  #   # boot_package contains U-Boot (Offset: 16400KB)
  #   dd if=${ubootOrangePi4Pro}/boot_package.fex of=$img seek=16400 conv=notrunc bs=1k
  # '';

  # todo: remove the blobs and build the images directly
  # captured with these commands:
  # LOOP=$(sudo losetup -fP --show Armbian_*.img) && sudo mount "${LOOP}p1" /mnt/tmp
  # cp /mnt/tmp/usr/lib/linux-u-boot-*/boot0_sdcard.fex ./blob/armbian-boot0_sdcard.fex
  # cp /mnt/tmp/usr/lib/linux-u-boot-*/boot_package.fex ./blob/armbian-boot_package.fex
  # sudo umount /mnt/tmp && sudo losetup -d "$LOOP"
  # echo "Flashing Armbian-built Allwinner boot0 and boot_package (known-good on hardware)..."
  # dd if=${./blobs/armbian-boot0_sdcard.fex} of=$img seek=8 conv=notrunc bs=1k
  # dd if=${./blobs/armbian-boot_package.fex} of=$img seek=16400 conv=notrunc bs=1k
  sdImage.postBuildCommands = /* bash */ ''
    echo "Flashing locally built Allwinner boot0 and boot_package..."
    dd if=${ubootOrangePi4Pro}/boot0_sdcard.fex of=$img seek=8 conv=notrunc bs=1k
    dd if=${ubootOrangePi4Pro}/boot_package.fex of=$img seek=16400 conv=notrunc bs=1k
  '';

  sdImage.firmwareSize = 256;
  sdImage.firmwarePartitionOffset = 48; # MiB — must clear boot_package.fex, which starts at 16.4MiB

  system.build.opi4proUboot = ubootOrangePi4Pro;

  fileSystems."/boot/firmware" = {
    device = "/dev/disk/by-label/FIRMWARE";
    fsType = "vfat";
    options = [
      "nofail"
      "umask=0077"
    ];
  };
}
