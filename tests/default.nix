{ pkgs, inputs, ... }:
let
  outerPkgs = pkgs;
in
{
  name = "boot-test";
  nodes.machine =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    {
      _module.args.inputs = inputs;
      nixpkgs.pkgs = lib.mkForce (
        import inputs.nixpkgs {
          inherit (outerPkgs) system;
          config.allowUnfree = false;
        }
      );
      nixpkgs.config = lib.mkForce { };
      imports = [
        ../serverbase.nix
        inputs.sops-nix.nixosModules.sops
        inputs.home-manager.nixosModules.home-manager
        {
          networking.hostName = "pitest";
          setup.username = "giggio";
        }
      ];
      # Use a dummy key path for sops to pass evaluation
      sops.age.keyFile = lib.mkForce "/var/lib/sops/dummy.agekey";

      # Needs to be a virtual machine
      virtualisation.memorySize = 1024;
      virtualisation.cores = 2;
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.succeed("id giggio")
    machine.succeed("hostname | grep pitest")
  '';
}
