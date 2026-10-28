{ testNodes, pkgs, ... }:

# Covers the kernel sysctls and the resolver settings of modules/serverbase/default.nix: the defaults that serve nobody
# here but whoever got a process on the machine. The kernel is nixpkgs' in this VM, so on a board with a kernel of its
# own this proves the configuration, and the board's kernel is read on the board.
{
  name = "base-kernel-defaults";

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

    with subtest("the sysctls are applied"):
        for key, expected in [
            ("kernel.io_uring_disabled", "2"),
            ("kernel.kexec_load_disabled", "1"),
            ("dev.tty.ldisc_autoload", "0"),
            ("net.ipv6.conf.all.accept_redirects", "0"),
            ("net.ipv6.conf.default.accept_redirects", "0"),
        ]:
            value = machine.succeed(f"sysctl -n {key}").strip()
            assert value == expected, f"{key} is {value}, expected {expected}"

    with subtest("io_uring_setup is refused to root and to an unprivileged user alike"):
        # the syscall itself rather than the sysctl, which says nothing about whether the kernel honours it
        probe = (
            "${pkgs.python3}/bin/python3 -c '"
            "import ctypes, errno, sys; libc = ctypes.CDLL(None, use_errno=True); "
            "params = ctypes.create_string_buffer(120); result = libc.syscall(425, 1, params); "
            "sys.exit(0 if result == -1 and ctypes.get_errno() == errno.EPERM "
            "else f\"io_uring_setup returned {result}, errno {ctypes.get_errno()}\")'"
        )
        machine.succeed(probe)
        machine.succeed(f"runuser -u giggio -- {probe}")

    with subtest("kexec is refused"):
        (status, output) = machine.execute(
            "${pkgs.kexec-tools}/bin/kexec -l /run/current-system/kernel --initrd=/run/current-system/initrd 2>&1"
        )
        # refused by the sysctl, and not by anything else that makes kexec fail
        assert status != 0 and "Operation not permitted" in output, f"kexec -l exited {status}: {output}"

    with subtest("resolved neither asks nor answers LLMNR and mDNS"):
        machine.wait_for_unit("systemd-resolved.service")
        # read whole: `grep -m1` stops early, and resolvectl dying of SIGPIPE fails the pipeline under pipefail
        status = machine.succeed("resolvectl status")
        protocols = next(line for line in status.splitlines() if "Protocols:" in line)
        assert "-LLMNR" in protocols and "-mDNS" in protocols, f"resolved still speaks them: {protocols}"
        listeners = machine.succeed("ss -Hlnu").splitlines()
        assert not [line for line in listeners if ":5355 " in line or ":5353 " in line], \
            f"something listens for LLMNR or mDNS: {listeners}"

    (_, failed) = machine.systemctl("--failed --quiet")
    machine.log(f"systemctl --failed output: {failed}")
    assert "" == failed, "Expected no failed units and got: " + failed
  '';
}
