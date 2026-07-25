{ testNodes, ... }:

{
  name = "boot-test";
  nodes.machine = {
    imports = [
      testNodes.base
      {
        setup = {
          hostName = "nixos";
          username = "giggio";
        };
      }
    ];
  };

  testScript = /* python */ ''
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
