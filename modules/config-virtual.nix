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

  setup.vm = {
    enable = true;
    extraCreateCommands = /* bash */ ''
      # Creating the VM
      echo "Creating the vm..."
    '';
    extraStartCommands = /* bash */ ''
      # extra start commands would
      # go here
    '';
  };

  virtualisation = {
    useEFIBoot = config.setup.vm.useEFIBoot;
    writableStoreUseTmpfs = false; # allows to save changes to the nix store and get it to working when rebooted
    qemu = {
      guestAgent.enable = true;
      virtioKeyboard = false; # connections go through serial port
      networkingOptions =
        let
          httpPort = if config.setup.isDev then 8888 else 80;
          httpsPort = if config.setup.isDev then 4443 else 443;
        in
        lib.mkForce [
          # remove other nic options with lib.mkForce
          ''-netdev user,id=mynet0,ipv6=off,hostfwd=tcp::8888-:${toString httpPort},hostfwd=tcp::4443-:${toString httpsPort},hostfwd=tcp::4445-:445,hostfwd=tcp::2222-:22,"$QEMU_NET_OPTS"''
          "-device virtio-net-pci,netdev=mynet0,mac=52:54:00:CA:FE:EE"
        ];
      options = [
        "-enable-kvm"
        "-serial unix:/tmp/$VM_NAME.sock,server,nowait"
      ];
      drives = lib.mkMerge [
        [
          {
            driveExtraOpts.werror = "report";
            file = "$VM_DIR/secret-disk.qcow2";
          }
        ]
        (lib.lists.imap1 (idx: imgCfg: {
          driveExtraOpts.werror = "report";
          file = "$VM_DIR/disk${toString idx}.qcow2";
        }) config.setup.vm.extraDisks)
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

  security.sudo.wheelNeedsPassword = false; # VM-only: allow non-interactive sudo (e.g. over ssh) for test/debugging convenience

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
