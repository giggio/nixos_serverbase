{
  lib,
  modulesPath,
  inputs,
  ...
}:

let
  # ---------------------------------------------------------------------------------------------------------------------------
  # The kernel is PINNED to nixpkgs-bootchain and CROSS-compiled from x86_64, not built natively under emulation.
  # ---------------------------------------------------------------------------------------------------------------------------
  # nixos-hardware builds `linux-rpi` from the raspberrypi/linux vendor tree, and Hydra does not build nixos-hardware, so this
  # kernel is in no public cache - whoever evaluates it compiles it. Left on the tracking `nixpkgs`, a stdenv-level backport - a
  # glibc CVE patch is enough - rehashes the derivation even though the kernel source is byte-identical, so `nix flake update`
  # rebuilt it EVERY WEEK. Measured on the CI runner: 3 hours cross-compiled, and over an hour more than that emulated. That is
  # what the two measures below are for, and they address different halves of the problem.
  #
  # PINNING (nixpkgs-bootchain) is what makes the rebuild stop happening. It is the same input, and for the same reason, as the
  # opi4pro boot chain in modules/config-physical-opi4pro-common.nix - see the comment on the input in flake.nix. Only the
  # toolchain that compiles the kernel is pinned; the kernel SOURCE comes from nixos-hardware, which `nix flake update` still
  # moves, so kernel security updates arrive exactly as before. What is given up is stdenv fixes for a package that links
  # against no pinned userland at runtime - a kernel image has no dynamic dependencies at all.
  #
  # CROSS-COMPILING is what makes the rebuild cheap on the weeks it does happen - a nixos-hardware bump to the vendor kernel, or
  # a bump of the pin. It turns an emulated aarch64 compile into a native x86_64 one targeting aarch64: the aarch64 GCC,
  # binutils and glibc all come prebuilt from cache.nixos.org, and only the kernel itself is built.
  #
  # The build platform is hardcoded rather than taken from the evaluating machine on purpose: the pi has to evaluate the same
  # derivation the builder pushed, or it would see a cache miss and start building its own kernel. The flip side is that a
  # `nixos-rebuild` on the pi itself can no longer fall back to compiling this locally - it depends on the closure being in the
  # cache, which is exactly what the weekly CI job guarantees.
  crossPkgs = import inputs.nixpkgs-bootchain {
    localSystem = "x86_64-linux";
    crossSystem = "aarch64-linux";
    config = { };
  };

  # Rust has to be off for the cross build to be worth anything. nixpkgs' common-config turns CONFIG_RUST on whenever rustc is
  # available for the host platform, which drags rustc, cargo, rustfmt and bindgen into nativeBuildInputs - and for a cross
  # build those are `aarch64-unknown-linux-gnu-rustc` and friends, which Hydra does not build either. Leaving it on replaces an
  # hour of emulated kernel build with a from-source cross Rust toolchain every week, which is worse. Nothing here uses an
  # in-tree Rust driver; the cost of turning it off is DRM_PANIC and the Rust driver infrastructure, neither of which this
  # board has ever used.
  #
  # It is injected by wrapping `buildLinux` rather than by passing `structuredExtraConfig`, because nixos-hardware's kernel.nix
  # overwrites that argument with its own set (NR_CPUS, CMA_SIZE_MBYTES, the preempt model, ...). Wrapping intercepts the exact
  # attribute set it hands to buildLinux, so their settings survive verbatim and a change on their side is picked up instead of
  # being silently replaced by a stale copy.
  kernel = crossPkgs.callPackage "${inputs.nixos-hardware}/raspberry-pi/common/kernel.nix" {
    rpiVersion = 4;
    buildLinux =
      attrs:
      crossPkgs.buildLinux (
        attrs
        // {
          structuredExtraConfig = (attrs.structuredExtraConfig or { }) // {
            RUST = lib.mkForce lib.kernel.no;
          };
        }
      );
  };
in
{
  imports = [
    "${modulesPath}/installer/sd-card/sd-image-aarch64.nix"
    inputs.nixos-hardware.nixosModules.raspberry-pi-4
  ];

  boot = {
    # Overrides the `lib.mkDefault` nixos-hardware sets, with the same kernel built for the same board - the only difference
    # is which machine compiles it, and the CONFIG_RUST above.
    kernelPackages = crossPkgs.linuxPackagesFor kernel;
    supportedFilesystems.zfs = lib.mkForce false; # todo: remove this when zfs is supported
    kernelModules = [ "bcm2835-v4l2" ]; # originally missing, as we are not using the vendored kernel
    kernelParams = lib.mkForce [
      "console=tty0"
      # ttyAMA0 (PL011), not ttyS0 (mini-UART): this kernel's pinctrl-bcm2835 driver registers
      # zero named pin groups from any brcm,pins-style DT subnode - confirmed on both nixpkgs'
      # own compiled dtb and the vendor's prebuilt one - so bcm2835-aux-uart (mini-UART) always
      # fails to probe ("not valid maps for state default" -> EINVAL). uart-pl011 tolerates the
      # same missing mapping and keeps working, and the GPU firmware (not the buggy Linux driver)
      # is what actually reroutes GPIO14/15 to it via dtoverlay=disable-bt below - so this side
      # steps the kernel bug entirely instead of depending on a fix for it. Has to be the last tty
      # so it becomes the primary /dev/console for connections with picocom through serial to work.
      "console=ttyAMA0,115200n8"
      "loglevel=7"
      "lsm=landlock,yama,bpf"
    ];
    initrd = {
      availableKernelModules = {
        # todo: remove this when this is fixed: https://github.com/NixOS/nixpkgs/issues/154163
        # related: https://github.com/NixOS/nixpkgs/issues/109280
        # related: https://discourse.nixos.org/t/cannot-build-raspberry-pi-sdimage-module-dw-hdmi-not-found/71804
        dw-hdmi = lib.mkForce false;
        dw-mipi-dsi = lib.mkForce false;
        rockchipdrm = lib.mkForce false;
        rockchip-rga = lib.mkForce false;
        phy-rockchip-pcie = lib.mkForce false;
        pcie-rockchip-host = lib.mkForce false;
        pwm-sun4i = lib.mkForce false;
        sun4i-drm = lib.mkForce false;
        sun8i-mixer = lib.mkForce false;
      };
    };
  };

  hardware.raspberry-pi = {
    firmware = {
      enable = true;
      # This board boots via U-Boot reading extlinux.conf (boot.loader.generic-extlinux-compatible),
      # not the firmware's native extlinux support. Without this, the generated config.txt has no
      # "kernel=" line at all, and the GPU firmware would have nothing to chainload - a hard brick,
      # not just a missing console.
      uboot.enable = true;
      # dtoverlay=disable-bt below needs its .dtbo staged on the firmware partition, which
      # requires copying from the vendor firmware package (cfg.package) rather than NixOS's own
      # filtered /run/current-system/dtbs (which has no overlays/ at all).
      useGenerationDeviceTree = false;
    };
    configtxt.settings.pi4 = {
      # Frees the PL011 UART (normally wired to onboard Bluetooth) and reroutes it to GPIO14/15,
      # in place of the mini-UART that's normally there by default. Trades onboard Bluetooth for
      # a working physical serial console - see the comment on console=ttyAMA0 above for why.
      dtoverlay = "disable-bt";
    };
  };

  # nixpkgs' sd-image.nix already defines fileSystems."/boot/firmware" (device/fsType), but with
  # "noauto" in its options - it's treated as an opaque blob, never mounted at runtime. Without a
  # mount, nixos-hardware's activation script (hardware.raspberry-pi.firmware.enable) can't find
  # it and silently skips, so config.txt changes (like the one above) would only reach the card
  # on the next SD-image rebuild + reflash. mkForce here drops "noauto" (options is a list, so a
  # plain re-declaration would merge instead of replace it) while keeping "nofail" so a firmware
  # partition problem still can't block boot.
  fileSystems."/boot/firmware".options = lib.mkForce [ "nofail" ];
}
