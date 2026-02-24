{
  config,
  modulesPath,
  lib,
  ...
}:

{

  assertions = [
    {
      assertion = config.setup.vm.diskSize >= 20;
      message = "VM disk size must be at least 20GB and was ${toString config.setup.vm.diskSize}GB";
    }
    {
      assertion = config.setup.vm.memorySize >= 4;
      message = "VM memory size must be at least 4GB and was ${toString config.setup.vm.memorySize}GB";
    }
  ];

  imports = [
    "${toString modulesPath}/virtualisation/qemu-vm.nix"
  ];

  setup.vm.enable = true;

  virtualisation = {
    useEFIBoot = config.setup.vm.useEFIBoot;
    qemu = {
      guestAgent.enable = true;
      virtioKeyboard = false; # connections go through serial port
      networkingOptions = lib.mkForce [
        # remove other nic options with lib.mkForce
        ''-nic user,ipv6=off,model=virtio,mac=52:54:00:CA:FE:EE,hostfwd=tcp::2222-:22,"$QEMU_NET_OPTS"''
      ];
      options = [
        "-enable-kvm"
      ];
    };
    graphics = false; # connection is via serial port
    cores = 4;
    memorySize =
      let
        memorySize = config.setup.vm.memorySize * 1024;
      in
      builtins.traceVerbose "VM memory size: ${toString memorySize}" memorySize;
    diskSize =
      let
        diskSize = config.setup.vm.diskSize * 1024;
      in
      builtins.traceVerbose "VM disk size: ${toString diskSize}" diskSize;
  };

  boot = {
    loader = {
      # disables boot loaders, are vms are using the nix store from the host
      # if needing to test with a boot loader these need to be set to false
      # a good option in this case is using the ISO installation, which will always produce a boot loader
      systemd-boot.enable = false;
      grub.enable = false;
    };
    kernelParams = [
      "console=ttyS0,115200n8" # this is for the serial console so connections with socat work
    ];
  };
}
