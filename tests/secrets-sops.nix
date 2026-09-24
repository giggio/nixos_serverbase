{ testNodes, ... }:

# Covers modules/serverbase/secrets.nix and the two sops templates the base configuration renders. What is worth proving
# here is the wiring, not that sops can decrypt: that every declared secret arrives where the rest of the configuration
# expects it, with the ownership that lets the right processes read it, and that the templates come out with the
# placeholders actually substituted - a template whose placeholder is misspelled renders perfectly happily with the
# placeholder text still in it.
#
# Two nodes, because the config repository credentials exist only where `setup.nixosConfig.useCredentials` asks for
# them: `machine` is every server as it is configured today, and `credentials` is one that clones with them.
#
# The machines' own secrets cannot be used, since only the servers hold the key, so the fixtures come from
# testNodes.fakeSecrets (modules/test-secrets.nix): encrypted at build time, with the plaintext stated right here.
let
  baseValues = {
    # an ordinary nix setting whose default is not 7, so that reading it back proves the include was honoured
    nixExtraSecretOptions = "connect-timeout = 7\n";
  };
  credentialValues = {
    "config_repo_clone/user" = "test-config-repo-user";
    "config_repo_clone/pat" = "test-config-repo-pat";
  };
  node = values: extra: {
    imports = [
      testNodes.base
      (testNodes.fakeSecrets {
        names = builtins.attrNames values;
        inherit values;
      })
      {
        setup = {
          hostName = "nixos";
          username = "giggio";
        };
      }
      extra
    ];
  };
in
{
  name = "secrets-sops";

  nodes = {
    machine = node baseValues { };
    credentials = node (baseValues // credentialValues) { setup.nixosConfig.useCredentials = true; };
  };

  testScript = # python
    ''
      start_all()
      machine.wait_for_unit("multi-user.target")
      credentials.wait_for_unit("multi-user.target")

      def secret(node, path):
          return node.succeed(f"cat /run/secrets/{path}").strip()

      def ownership(node, path):
          return node.succeed(f"stat -c '%a %U %G' /run/secrets/{path}").strip()

      with subtest("without useCredentials there is no config repository credential, nor a template for one"):
          # The key is also absent from the fixture, so a declaration left behind fails the whole secrets activation,
          # and then everything below is absent for the wrong reason. Hence the check that the rest did arrive.
          machine.succeed("test -e /run/secrets/nixExtraSecretOptions")
          machine.fail("test -e /run/secrets/config_repo_clone")
          machine.fail("test -e /run/secrets/rendered/git-askpass")

      with subtest("with useCredentials the credentials are decrypted and readable only by root"):
          for path, expected in [
              ("config_repo_clone/user", "${credentialValues."config_repo_clone/user"}"),
              ("config_repo_clone/pat", "${credentialValues."config_repo_clone/pat"}"),
          ]:
              value = secret(credentials, path)
              assert value == expected, f"secret {path} decrypted to '{value}', expected '{expected}'"
              mode = ownership(credentials, path)
              assert mode == "400 root root", f"secret {path} is '{mode}', expected '400 root root'"

      with subtest("the git askpass template carries the config repo credentials"):
          askpass = secret(credentials, "rendered/git-askpass")
          assert "username=${credentialValues."config_repo_clone/user"}" in askpass, \
              f"no username in the askpass file: {askpass}"
          assert "password=${credentialValues."config_repo_clone/pat"}" in askpass, \
              f"no password in the askpass file: {askpass}"

      with subtest("no attic credential reaches the machine, and nix is not looking for one"):
          # The cache substitutes anonymously, so there is no netrc to build. Both halves are asserted because
          # removing the template while leaving `netrc-file` behind would point nix at a path nothing creates,
          # and nix does not complain about that - it just stops authenticating, which looks like a flaky cache.
          machine.fail("test -e /run/secrets/rendered/attic_netrc")
          machine.fail("test -e /run/secrets/attic_token")
          netrc_setting = machine.succeed("nix config show netrc-file").strip()
          assert not netrc_setting.startswith("/run/secrets"), \
              f"nix is still pointed at a sops-rendered netrc: '{netrc_setting}'"

      with subtest("the secret nix options are included into the daemon's configuration"):
          mode = ownership(machine, "nixExtraSecretOptions")
          assert mode == "440 root users", f"the extra nix options are '{mode}', expected '440 root users'"
          # read back through nix itself: this only holds if the `!include` in nix.conf resolved and was parsed
          timeout = machine.succeed("nix config show connect-timeout").strip()
          assert timeout == "7", \
              f"connect-timeout is '{timeout}', so the secret options file was not included"

      with subtest("the SSH host keys are not imported as sops identities"):
          # On a first boot sshd creates the host keys after activation has already run, so activate again once
          # they exist: that is every later boot and every deploy on a real machine.
          machine.wait_for_unit("sshd.service")
          machine.succeed("test -e /etc/ssh/ssh_host_ed25519_key -a -e /etc/ssh/ssh_host_rsa_key")
          activation = machine.succeed("/run/current-system/activate 2>&1")
          assert "/etc/ssh/" not in activation, \
              f"sops-install-secrets still reads an SSH host key as an identity:\n{activation}"

      for node in [machine, credentials]:
          (_, failed) = node.systemctl("--failed --quiet")
          node.log(f"systemctl --failed output: {failed}")
          assert "" == failed, "Expected no failed units and got: " + failed
    '';
}
