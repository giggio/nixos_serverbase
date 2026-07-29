{
  lib,
  modulesPath,
  inputs,
  ...
}:

{
  imports = [
    "${modulesPath}/installer/sd-card/sd-image-aarch64.nix"
    inputs.nixos-hardware.nixosModules.raspberry-pi-4
  ];

  boot = {
    # kernelPackages is being set by nixos-hardware
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
