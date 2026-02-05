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
      _module.args.helpers = import ../modules/helpers { inherit lib; };
      nixpkgs.pkgs = lib.mkForce (
        import inputs.nixpkgs {
          inherit (outerPkgs) system;
          config.allowUnfree = false;
        }
      );
      nixpkgs.config = lib.mkForce { };
      imports = inputs.self.nixosModules.default ++ [
        {
          setup = {
            hostName = "nixos";
            username = "giggio";
            nixosConfig.useCredentials = false;
            environment = "test";
          };
        }
      ];
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.succeed("id giggio")
    machine.succeed("hostname | grep nixos")
    machine.succeed("grep true /etc/isdev")
    machine.succeed("grep true /etc/istest")
    (_, failed) = machine.systemctl("--failed --quiet")
    machine.log(f"systemctl --failed output: {failed}")
    assert "" == failed, "Expected no failed units and got: " + failed
  '';
}
