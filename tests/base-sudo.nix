{
  pkgs,
  inputs,
  testNodes,
  ...
}:

# Covers modules/serverbase/sudo.nix: sudo-rs, and sudo answered by a key in an agent that the client forwards with a
# RemoteForward to a fixed socket. The test plays the PC itself: root holds an agent and logs in as the user over ssh with
# the forward, the same shape as the real client config, so what is exercised is sshd's forward, the socket path, the
# PAM stack and the key file together.
#
# The real sudo key is a FIDO2 key and needs a touch, which a VM cannot give. A plain ed25519 key stands in for it here;
# the touch itself - pam_rssh refusing a security-key signature without the user-presence bit - is covered by the unit
# tests the patch adds to pam_rssh's own build (modules/serverbase/pkgs).
let
  inherit (import "${inputs.nixpkgs}/nixos/tests/ssh-keys.nix" pkgs)
    snakeOilPrivateKey
    snakeOilPublicKey
    snakeOilEd25519PrivateKey
    snakeOilEd25519PublicKey
    ;
  user = "giggio";
  agentSocket = "/run/user/1000/ssh-remote-agent.sock";
in
{
  name = "base-sudo";

  nodes.machine = {
    imports = [
      testNodes.base
      {
        setup = {
          hostName = "nixos";
          username = user;
          # the ed25519 key is the sudo key; the ecdsa one only logs in
          sudoKeys = [ snakeOilEd25519PublicKey ];
        };
        users.users.${user}.openssh.authorizedKeys.keys = [ snakeOilPublicKey ];
      }
    ];
  };

  testScript = /* python */ ''
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("sshd.service")
    machine.wait_for_open_port(22)

    machine.succeed("install -m 0600 ${snakeOilPrivateKey} /root/login-key")
    machine.succeed("install -m 0600 ${snakeOilEd25519PrivateKey} /root/sudo-key")
    # two agents on "the PC": one with the sudo key, one with only the login key
    machine.succeed("ssh-agent -a /root/sudo-agent.sock")
    machine.succeed("SSH_AUTH_SOCK=/root/sudo-agent.sock ssh-add /root/sudo-key")
    machine.succeed("ssh-agent -a /root/login-agent.sock")
    machine.succeed("SSH_AUTH_SOCK=/root/login-agent.sock ssh-add /root/login-key")

    def ssh(command, forward=None):
        """Runs `command` as the user over ssh, forwarding the agent at `forward` the way the PC does."""
        options = (
            "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10"
            " -o IdentitiesOnly=yes -i /root/login-key"
        )
        if forward:
            options += f" -o RemoteForward={'${agentSocket}'}:{forward}"
        # SSH_AUTH_SOCK is emptied so the client authenticates with the login key file alone and never with the agent
        # being forwarded - the sudo key must not be the thing that got it in
        return machine.execute(f"SSH_AUTH_SOCK= ssh {options} ${user}@localhost '{command}' 2>&1")

    # -k so a timestamp from an earlier subtest does not answer for this one, -S with an empty stdin so that falling
    # through to the password fails at once instead of waiting on a terminal
    sudo = "sudo -k -S true < /dev/null"

    with subtest("sudo is sudo-rs, with the timeout written out"):
        version = machine.succeed("sudo --version")
        assert "sudo-rs" in version, f"sudo is not sudo-rs: {version}"
        machine.succeed("grep -qx 'Defaults timestamp_timeout=15' /etc/sudoers")

    with subtest("the trusted keys live in a root-owned file that the user cannot change"):
        ownership = machine.succeed("stat -c '%U %a' -L /etc/ssh/sudo_keys/${user}").strip()
        assert ownership in ("root 444", "root 644"), f"/etc/ssh/sudo_keys/${user} is '{ownership}'"
        machine.succeed("grep -qF '${snakeOilEd25519PublicKey}' /etc/ssh/sudo_keys/${user}")

    with subtest("a session from the PC finds the forwarded agent at the fixed socket"):
        (status, out) = ssh("echo SOCK=$SSH_AUTH_SOCK", forward="/root/sudo-agent.sock")
        assert status == 0, f"ssh failed: {out}"
        assert "SOCK=${agentSocket}" in out, f"SSH_AUTH_SOCK is not the fixed socket: {out}"
        (status, out) = ssh("ssh-add -l", forward="/root/sudo-agent.sock")
        assert status == 0 and "ED25519" in out, f"the forwarded agent is not reachable at the fixed socket: {out}"

    with subtest("the sudo key in the forwarded agent is enough for sudo, and for sudo -g"):
        (status, out) = ssh(sudo, forward="/root/sudo-agent.sock")
        assert status == 0, f"sudo through the agent failed: {out}"
        assert "Please touch the device." in out, f"sudo did not tell the user to touch the key: {out}"
        # restore_backup.sh in the superproject asks to be run like this
        (status, out) = ssh("sudo -k -S -u root -g users id -gn < /dev/null", forward="/root/sudo-agent.sock")
        assert status == 0 and "users" in out, f"sudo -g through the agent failed: {out}"

    with subtest("an agent without the sudo key falls through to the password"):
        # the login key also sits in the user's own authorized_keys, the upstream default key file, to show that one
        # is not read
        machine.succeed(
            "install -d -m 0700 -o ${user} -g users /home/${user}/.ssh"
            " && echo '${snakeOilPublicKey}' > /home/${user}/.ssh/authorized_keys"
            " && chown ${user}:users /home/${user}/.ssh/authorized_keys"
        )
        (status, out) = ssh(sudo, forward="/root/login-agent.sock")
        assert status != 0, f"sudo accepted a key that is not in the sudo keys: {out}"

    with subtest("without the forward, sudo wants the password"):
        (status, out) = ssh(sudo)
        assert status != 0, f"sudo succeeded with no agent and no password: {out}"

    with subtest("git pushes to the forge share one connection, and nothing else does"):
        config = machine.succeed("su - ${user} -c 'ssh -G -l forgejo forge.example'")
        assert "controlmaster auto" in config and "controlpersist 600" in config, \
            f"a forge push does not share its connection: {config}"
        config = machine.succeed("su - ${user} -c 'ssh -G -l ${user} other.example'")
        assert "controlmaster false" in config, f"connections other than the forge's are shared too: {config}"

    (_, failed) = machine.systemctl("--failed --quiet")
    machine.log(f"systemctl --failed output: {failed}")
    assert "" == failed, "Expected no failed units and got: " + failed
  '';
}
