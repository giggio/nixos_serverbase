{ testNodes, ... }:

# gmktec1 runs the stock docker daemon plus the extra daemons declared in modules/config-gmktec.nix (`kata` on subnet octet
# 39, `other` on 40). This checks that all of them come up, that each one really landed on its configured bridge subnet -
# dockerd persists the subnet it first derived, so a mismatch here is the failure mode that silently breaks container
# networking - and that a container on an extra daemon gets an address on that subnet and can talk to its gateway.
# Running an actual kata container is out of scope: that needs nested KVM, which the test VM does not have, so only the
# runtime registration is checked.
{
  name = "gmktec1-docker";

  nodes.machine = {
    imports = [
      (testNodes.machine "gmktec1")
      (
        { pkgs, ... }:
        {
          virtualisation = {
            memorySize = 4096;
            diskSize = 8192;
            cores = 2;
          };
          # There is no network in the test sandbox, so the image has to come from the store. busybox gives the container
          # the `ip` and `ping` it needs to inspect its own networking.
          environment.etc."docker-test-image.tar.gz".source = pkgs.dockerTools.buildImage {
            name = "nettest";
            tag = "latest";
            copyToRoot = pkgs.buildEnv {
              name = "nettest-root";
              paths = [ pkgs.busybox ];
              pathsToLink = [ "/bin" ];
            };
            config.Cmd = [ "/bin/sh" ];
          };
        }
      )
    ];
  };

  testScript = /* python */ ''
    machine.wait_for_unit("multi-user.target")

    with subtest("every docker and containerd daemon is running"):
        for unit in ["docker.service",
                     "docker-kata.service", "containerd-kata.service",
                     "docker-other.service", "containerd-other.service"]:
            machine.wait_for_unit(unit)

    with subtest("extra daemons expose their own socket to the docker group"):
        for name in ["kata", "other"]:
            machine.wait_for_file(f"/run/docker-{name}.sock")
            perms = machine.succeed(f"stat -c '%a %G' /run/docker-{name}.sock").strip()
            assert perms == "660 docker", \
                f"/run/docker-{name}.sock is '{perms}', expected '660 docker'"

    with subtest("each extra daemon sits on its configured bridge subnet"):
        for name, octet in [("kata", 39), ("other", 40)]:
            machine.succeed(f"ip -4 -o addr show container-{name} | grep -F '172.{octet}.0.1/16'")
            subnet = machine.succeed(
                f"docker -H unix:///run/docker-{name}.sock network inspect bridge"
                " | jq -r '.[0].IPAM.Config[0].Subnet'"
            ).strip()
            assert subnet == f"172.{octet}.0.0/16", \
                f"docker-{name} bridge network is on {subnet}, expected 172.{octet}.0.0/16"

    with subtest("the default daemon runs a container"):
        machine.succeed("docker load --input /etc/docker-test-image.tar.gz")
        machine.succeed("docker run --rm nettest:latest /bin/true")

    with subtest("a container on docker-other is addressed on 172.40.0.0/16 and reaches its gateway"):
        other = "docker -H unix:///run/docker-other.sock"
        machine.succeed(f"{other} load --input /etc/docker-test-image.tar.gz")
        address = machine.succeed(f"{other} run --rm nettest:latest ip -4 -o addr show eth0")
        machine.log(f"container address: {address}")
        assert "inet 172.40." in address, \
            f"container did not get an address on 172.40.0.0/16: {address}"
        machine.succeed(f"{other} run --rm nettest:latest ping -c 1 -W 5 172.40.0.1")

    with subtest("the kata daemon registers kata as its default runtime"):
        kata = "docker -H unix:///run/docker-kata.sock"
        runtimes = machine.succeed(kata + " info --format '{{json .Runtimes}}'")
        assert "kata" in runtimes, f"docker-kata does not know the kata runtime: {runtimes}"
        default_runtime = machine.succeed(kata + " info --format '{{.DefaultRuntime}}'").strip()
        assert default_runtime == "kata", \
            f"docker-kata default runtime is '{default_runtime}', expected 'kata'"

    (_, failed) = machine.systemctl("--failed --quiet")
    machine.log(f"systemctl --failed output: {failed}")
    assert "" == failed, "Expected no failed units and got: " + failed
  '';
}
