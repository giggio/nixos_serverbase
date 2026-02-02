{
  config,
  modulesPath,
  inputs,
  ...
}:

{

  assertions = [
    {
      assertion = config.setup.vmDiskSize >= 20;
      message = "VM disk size must be at least 20GB and was ${toString config.setup.vmDiskSize}GB";
    }
    {
      assertion = config.setup.vmDiskSize <= 30;
      message = "VM disk size must be at most 30GB and was ${toString config.setup.vmDiskSize}GB (it fails with out of memory errors otherwise)";
    }
    {
      assertion = config.setup.vmMemorySize >= 4;
      message = "VM memory size must be at least 4GB and was ${toString config.setup.vmMemorySize}GB";
    }
  ];

  imports = [
    "${toString modulesPath}/virtualisation/virtualbox-image.nix"
  ];

  setup.virtualbox = true;

  virtualbox = {
    vmName = config.setup.hostName;
    memorySize =
      let
        memorySize = config.setup.vmMemorySize * 1024;
      in
      builtins.trace "VM memory size: ${toString memorySize}" memorySize;
    baseImageFreeSpace = 30 * 1024;
  };

  virtualisation = {
    virtualbox.guest.enable = true;
    diskSize =
      let
        diskSize = config.setup.vmDiskSize * 1024;
      in
      builtins.trace "VM disk size: ${toString diskSize}" diskSize;
  };

  boot = {
    kernelParams = [
      "console=ttyS0,115200n8" # this is for the serial console so connections with socat work
    ];
  };
}
