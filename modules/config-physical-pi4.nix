{
  pkgs,
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
    kernelPackages = pkgs.pkgs.linuxPackages_rpi4; # vendored kernel
    supportedFilesystems.zfs = lib.mkForce false; # todo: remove this when zfs is supported
    kernelModules = [ "bcm2835-v4l2" ]; # originally missing, as we are not using the vendored kernel
    kernelParams = lib.mkForce [
      # removing console=ttyAMA0,115200n8, which breaks Pi4's Bluetooth
      "console=ttyS0,115200n8"
      "console=tty0"
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
}
