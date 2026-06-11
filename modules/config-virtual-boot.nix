{
  modulesPath,
  config,
  ...
}:

{
  imports = [
    (modulesPath + "/virtualisation/qemu-vm.nix")
    (modulesPath + "/profiles/qemu-guest.nix")
  ];
  setup.vm.enable = true;
  setup.vm.boot.enable = true;

  virtualisation = {
    useBootLoader = true;
    bootPartition = null;
    useEFIBoot = config.setup.vm.useEFIBoot;
    useDefaultFilesystems = false;
    fileSystems = config.disko.devices._config.fileSystems;
    writableStoreUseTmpfs = false; # allows to save changes to the nix store and get it to working when rebooted
    qemu = {
      guestAgent.enable = true;
    };
  };
}
