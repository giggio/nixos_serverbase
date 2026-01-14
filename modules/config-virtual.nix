{
  config,
  modulesPath,
  inputs,
  ...
}:

{
  imports = [
    inputs.nixos-generators.nixosModules.all-formats
    "${toString modulesPath}/virtualisation/virtualbox-image.nix"
  ];

  setup.virtualbox = true;

  virtualbox = {
    vmName = config.setup.hostName;
    memorySize = 4096;
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
