{
  pkgs,
  inputs,
  testNodes,
  ...
}:

# Covers the account and remote-access half of modules/serverbase/default.nix: the user and the groups that decide what
# it may do, the authorized key that is the only way in, sshd's settings, the logind policy, and the PAM hook that
# prepares the gnupg socket directory for a session. Most of this only ever shows up when someone logs in, so the test
# really logs in over ssh instead of inspecting configuration files.
let
  inherit (import "${inputs.nixpkgs}/nixos/tests/ssh-keys.nix" pkgs)
    snakeOilEd25519PrivateKey
    snakeOilEd25519PublicKey
    ;
  user = "giggio";
in
{
  name = "base-users-ssh";

  nodes.machine = {
    imports = [
      testNodes.base
      {
        setup = {
          hostName = "nixos";
          username = user;
        };
        # added alongside the real key, which the test asserts is still deployed
        users.users.${user}.openssh.authorizedKeys.keys = [ snakeOilEd25519PublicKey ];
      }
    ];
  };

  testScript = /* python */ ''
    machine.wait_for_unit("multi-user.target")

    with subtest("the user is a normal account in the groups that grant it privileges"):
        groups = set(machine.succeed("id -nG ${user}").split())
        for group in ["users", "wheel", "docker"]:
            assert group in groups, f"${user} is not in the '{group}' group, only in {sorted(groups)}"
        # NetworkManager is force-disabled, so this group must not appear either - if it ever does, the account silently
        # gained the right to reconfigure the network
        assert "networkmanager" not in groups, \
            "${user} is in the networkmanager group, but NetworkManager is supposed to be disabled"

        primary = machine.succeed("id -gn ${user}").strip()
        assert primary == "users", f"${user}'s primary group is '{primary}', expected 'users'"

        uid = int(machine.succeed("id -u ${user}").strip())
        assert uid >= 1000, f"${user} has uid {uid}, expected a normal user's uid"

    with subtest("the account has a password set, hashed with yescrypt"):
        hashed = machine.succeed("getent shadow ${user}").strip().split(":")[1]
        assert hashed.startswith("$y$"), \
            f"${user}'s password hash is not yescrypt: it starts with '{hashed[:3]}'"

    with subtest("the configured public key is deployed and no other way in is provisioned"):
        authorized = machine.succeed("cat /etc/ssh/authorized_keys.d/${user}")
        assert "openpgp:0x2E6F4761" in authorized, \
            "the configured ssh key is not in the user's authorized keys"

    with subtest("sshd is running and unlinks stale bound sockets"):
        machine.wait_for_unit("sshd.service")
        machine.wait_for_open_port(22)
        settings = machine.succeed("sshd -T")
        assert "streamlocalbindunlink yes" in settings.lower(), \
            "sshd does not have StreamLocalBindUnlink enabled, so forwarded sockets would not be reusable"

    with subtest("a session opened with an authorized key gets a private gnupg runtime directory"):
        machine.succeed("install -m 0600 ${snakeOilEd25519PrivateKey} /root/snakeoil-key")
        # BatchMode so that a rejected key fails outright instead of stalling on a password prompt
        machine.succeed(
            "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
            " -o BatchMode=yes -o ConnectTimeout=10"
            " -i /root/snakeoil-key ${user}@localhost true"
        )

        uid = machine.succeed("id -u ${user}").strip()
        gnupg = f"/run/user/{uid}/gnupg"
        machine.wait_for_file(gnupg)
        ownership = machine.succeed(f"stat -c '%a %U' {gnupg}").strip()
        assert ownership == "700 ${user}", \
            f"{gnupg} is '{ownership}', expected '700 ${user}' so that only the user can reach its agent sockets"

    with subtest("the pam hook is wired into the ssh service and not into every service"):
        machine.succeed("grep -q pam_exec.so /etc/pam.d/sshd")
        machine.fail("grep -q pam_exec.so /etc/pam.d/login")

    with subtest("logging out kills whatever the session left running"):
        # asked of logind itself rather than of its configuration file, so this is the value actually in effect
        setting = machine.succeed(
            "busctl get-property org.freedesktop.login1 /org/freedesktop/login1"
            " org.freedesktop.login1.Manager KillUserProcesses"
        ).strip()
        assert setting == "b true", \
            f"logind reports KillUserProcesses as '{setting}', expected 'b true'"

    (_, failed) = machine.systemctl("--failed --quiet")
    machine.log(f"systemctl --failed output: {failed}")
    assert "" == failed, "Expected no failed units and got: " + failed
  '';
}
