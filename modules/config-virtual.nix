{
  config,
  pkgs,
  modulesPath,
  ...
}:

{
  imports = [
    "${toString modulesPath}/virtualisation/virtualbox-image.nix"
  ];

  setup.virtualbox = true;

  virtualbox = {
    vmName = config.setup.hostName;
    memorySize = 4096;
  };

  boot = {
    # do not use pkgs.linuxPackages_latest, try to stay as close as possible to the kernel version used in the raspberry pi 4
    # check the version with: nix eval --raw nixpkgs#legacyPackages.aarch64-linux.linuxPackages_rpi4.kernel.version
    kernelPackages = pkgs.linuxPackages_6_12;
  };

  virtualisation = {
    virtualbox.guest.enable = true;
    diskSize = 20 * 1024;
  };

  boot = {
    kernelParams = [
      "console=ttyS0,115200n8" # this is for the serial console so connections with socat work
    ];
  };
}
