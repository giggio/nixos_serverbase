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

    # A SOFTWARE TPM, for the machines whose configuration expects a real one. `setup.secureBoot.tpmUnlock` runs
    # `systemd-cryptenroll --tpm2-device=auto` at boot, which fails on a VM that has no TPM at all - and since
    # gmktec1's root was sealed on 2026-09-01 that is not something a VM of it can opt out of any more.
    #
    # `or false` rather than a plain reference: the option only exists on machines that import the Secure Boot
    # module, which is the one with x86 firmware. The ARM boards have none, so on them this attribute is genuinely
    # absent rather than false.
    #
    # nixpkgs starts swtpm from the run script itself and appends the qemu arguments, so this is the whole change.
    # Where its state lands is NOT part of it: `NIX_SWTPM_DIR` defaults to a path relative to the working
    # directory, and the seed in it is what a sealed key is bound to - see the Makefile, which points it at
    # `$VM_DIR`.
    tpm.enable = config.setup.secureBoot.tpmUnlock.enable or false;

    bootPartition = null;
    useEFIBoot = config.setup.vm.useEFIBoot;
    useDefaultFilesystems = false;
    fileSystems = config.disko.devices._config.fileSystems;
    writableStoreUseTmpfs = false; # allows to save changes to the nix store and get it to working when rebooted
    qemu.guestAgent.enable = true;
  };

  boot = {
    kernelParams = [
      "console=tty0"
      "console=ttyS0,115200n8" # this is for the serial console so connections with socat work
    ];
  };
}
