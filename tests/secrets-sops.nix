{ testNodes, ... }:

# Covers modules/serverbase/secrets.nix and the two sops templates the base configuration renders. What is worth proving
# here is the wiring, not that sops can decrypt: that every declared secret arrives where the rest of the configuration
# expects it, with the ownership that lets the right processes read it, and that the templates come out with the
# placeholders actually substituted - a template whose placeholder is misspelled renders perfectly happily with the
# placeholder text still in it.
#
# The machines' own secrets cannot be used, since only the servers hold the key, so the fixtures come from
# testNodes.fakeSecrets (modules/test-secrets.nix): encrypted at build time, with the plaintext stated right here.
let
  secretValues = {
    "config_repo_clone/user" = "test-config-repo-user";
    "config_repo_clone/pat" = "test-config-repo-pat";
    # an ordinary nix setting whose default is not 7, so that reading it back proves the include was honoured
    nixExtraSecretOptions = "connect-timeout = 7\n";
  };
in
{
  name = "secrets-sops";

  nodes.machine = {
    imports = [
      testNodes.base
      (testNodes.fakeSecrets {
        names = builtins.attrNames secretValues;
        values = secretValues;
      })
      {
        setup = {
          hostName = "nixos";
          username = "giggio";
        };
      }
    ];
  };

  testScript = # python
    ''
      machine.wait_for_unit("multi-user.target")

      def secret(path):
          return machine.succeed(f"cat /run/secrets/{path}").strip()

      def ownership(path):
          return machine.succeed(f"stat -c '%a %U %G' /run/secrets/{path}").strip()

      with subtest("every declared secret is decrypted and readable only by root"):
          for path, expected in [
              ("config_repo_clone/user", "${secretValues."config_repo_clone/user"}"),
              ("config_repo_clone/pat", "${secretValues."config_repo_clone/pat"}"),
          ]:
              value = secret(path)
              assert value == expected, f"secret {path} decrypted to '{value}', expected '{expected}'"
              mode = ownership(path)
              assert mode == "400 root root", f"secret {path} is '{mode}', expected '400 root root'"

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
          mode = ownership("nixExtraSecretOptions")
          assert mode == "440 root users", f"the extra nix options are '{mode}', expected '440 root users'"
          # read back through nix itself: this only holds if the `!include` in nix.conf resolved and was parsed
          timeout = machine.succeed("nix config show connect-timeout").strip()
          assert timeout == "7", \
              f"connect-timeout is '{timeout}', so the secret options file was not included"

      with subtest("the git askpass template carries the config repo credentials"):
          askpass = secret("rendered/git-askpass")
          assert "username=${secretValues."config_repo_clone/user"}" in askpass, \
              f"no username in the askpass file: {askpass}"
          assert "password=${secretValues."config_repo_clone/pat"}" in askpass, \
              f"no password in the askpass file: {askpass}"

      (_, failed) = machine.systemctl("--failed --quiet")
      machine.log(f"systemctl --failed output: {failed}")
      assert "" == failed, "Expected no failed units and got: " + failed
    '';
}
