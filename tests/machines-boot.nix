{
  lib,
  machines,
  testNodes,
  ...
}:

# Boots every machine in the flake's machine list against its real module set, so that machine-specific configuration is
# proven to work and not merely to evaluate. The nodes are generated from that list: adding a machine to flake.nix gets
# it covered here without touching this file.
#
# What is exercised is the hardware-independent half of a machine (its `config-<machine>.nix` and its own modules). The
# `physical` half - disko layouts, bootloaders, board kernels - cannot run under the test driver, which brings its own
# VM; those are covered by building the img/iso packages instead.
let
  machineNames = map (machine: machine.name) machines;
in
{
  name = "machines-boot";

  nodes = lib.genAttrs machineNames (name: {
    imports = [
      (testNodes.machine name)
      {
        # enough headroom for the machines that bring up docker daemons on boot
        virtualisation.memorySize = 2048;
        # Taken from the VM configuration rather than from this node, so the check is that a test runs the same kernel
        # as the VM - for the boards that is a hand-picked approximation of the real one, and a test proving anything
        # about a different kernel would be proving it about a machine that does not exist.
        environment.etc."test/expected-kernel".text =
          (testNodes.vmConfigurationOf name).boot.kernelPackages.kernel.version;
      }
    ];
  });

  testScript = /* python */ ''
    machines_under_test = [
        ${lib.concatMapStringsSep "\n        " (name: ''("${name}", ${name}),'') machineNames}
    ]

    start_all()

    for name, machine in machines_under_test:
        with subtest(f"{name} boots and reports itself as a test machine"):
            machine.wait_for_unit("multi-user.target")

            # a test build is also a dev build, so the derived host name carries the dev suffix
            hostname = machine.succeed("hostname").strip()
            assert hostname == f"{name}dev", f"{name} calls itself '{hostname}', expected '{name}dev'"
            machine.succeed("grep true /etc/isdev")
            machine.succeed("grep true /etc/istest")

        with subtest(f"{name} booted the same kernel as the VM it is driven as"):
            expected = machine.succeed("cat /etc/test/expected-kernel").strip()
            running = machine.succeed("uname -r").strip()
            assert running.startswith(expected), \
                f"{name} is running kernel '{running}' but its VM runs '{expected}'"

        with subtest(f"{name} has no failed units"):
            (_, failed) = machine.systemctl("--failed --quiet")
            machine.log(f"systemctl --failed output for {name}: {failed}")
            assert "" == failed, f"Expected no failed units on {name} and got: " + failed
  '';
}
