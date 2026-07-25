{
  pkgs,
  lib,
  testNodes,
  ...
}:

# Covers modules/serverbase/secrets.nix and the two sops templates the base configuration renders. What is worth proving
# here is the wiring, not that sops can decrypt: that every declared secret arrives where the rest of the configuration
# expects it, with the ownership that lets the right processes read it, and that the templates come out with the
# placeholders actually substituted - a template whose placeholder is misspelled renders perfectly happily with the
# placeholder text still in it.
#
# The machines' own secrets cannot be used, since only the servers hold the key. Instead the fixtures below are encrypted
# at build time with a throwaway key, so the plaintext stays readable in this file and nothing has to be re-encrypted by
# hand when a secret is added.
let
  # Test-only age identity. It exists to encrypt the fixtures a few lines down and nothing else; no real secret is, or
  # ever should be, encrypted to it. It is committed on purpose, so that this check needs no setup to run.
  testAgePublicKey = "age1seqqa058acupwts8neefs5vdu8lwpz7hdyry000vd0xu5dp7nefqqc76wx";
  testAgeKeyFile = pkgs.writeText "test-age-key" ''
    AGE-SECRET-KEY-1MTQ3WT0F43GESK4XAP9Z2VLJ0W9TLR4UUL0EYX3HSPN95P4HJJ5SGCLFUM
  '';
  testKeyPath = "/run/test-age-key";

  secretValues = {
    codebergUser = "test-codeberg-user";
    codebergPat = "test-codeberg-pat";
    atticServer = "attic.test";
    atticToken = "test-attic-token";
  };
  # an ordinary nix setting whose default is not 7, so that reading it back proves the include was honoured
  extraNixOption = "connect-timeout = 7";

  encrypt =
    {
      name,
      format,
      text,
    }:
    pkgs.runCommand name
      {
        nativeBuildInputs = [ pkgs.sops ];
        inherit text;
        passAsFile = [ "text" ];
      }
      ''
        export SOPS_AGE_RECIPIENTS=${testAgePublicKey}
        sops --encrypt --input-type ${format} --output-type ${format} "$textPath" > $out
      '';

  sharedSecrets = encrypt {
    name = "test-shared-secrets.yaml";
    format = "yaml";
    text = ''
      codeberg_repo_clone:
        user: ${secretValues.codebergUser}
        pat: ${secretValues.codebergPat}
      attic_server: ${secretValues.atticServer}
      attic_token: ${secretValues.atticToken}
    '';
  };

  nixExtraOptions = encrypt {
    name = "test-nix-extra-options.conf";
    format = "binary";
    text = "${extraNixOption}\n";
  };
in
{
  name = "secrets-sops";

  nodes.machine = {
    imports = [
      testNodes.base
      {
        setup = {
          hostName = "nixos";
          username = "giggio";
        };
        sops = {
          age.keyFile = lib.mkForce testKeyPath;
          # the fixtures are only encrypted when their derivation is built, so there is nothing for sops-nix to inspect
          # at evaluation time. Dropping the check is safe here and only here: what it guards against - committing a
          # plaintext secret - cannot happen to a file that is generated.
          validateSopsFiles = false;
          defaultSopsFile = lib.mkForce sharedSecrets;
          secrets.nixExtraSecretOptions.sopsFile = lib.mkForce nixExtraOptions;
        };

        # On a server the key is installed from a USB stick during boot; a test has no operator to plug one in, so it is
        # laid down from the store instead. sops-nix refuses a keyFile that is itself in the store, and rightly so - the
        # store is world-readable - hence the copy, ordered before the secrets are decrypted.
        system.activationScripts = {
          testAgeKey = "install -D -m 0400 ${testAgeKeyFile} ${testKeyPath}";
          setupSecrets.deps = [ "testAgeKey" ];
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
              ("codeberg_repo_clone/user", "${secretValues.codebergUser}"),
              ("codeberg_repo_clone/pat", "${secretValues.codebergPat}"),
              ("attic_server", "${secretValues.atticServer}"),
              ("attic_token", "${secretValues.atticToken}"),
          ]:
              value = secret(path)
              assert value == expected, f"secret {path} decrypted to '{value}', expected '{expected}'"
              mode = ownership(path)
              assert mode == "400 root root", f"secret {path} is '{mode}', expected '400 root root'"

      with subtest("the attic netrc is rendered with the credentials substituted in"):
          netrc = secret("rendered/attic_netrc")
          assert netrc.splitlines() == [
              "machine ${secretValues.atticServer}",
              "password ${secretValues.atticToken}",
          ], f"the netrc template did not render as expected: {netrc}"
          # 0440 root:users, because nix runs the substituter as the calling user, not as root
          mode = ownership("rendered/attic_netrc")
          assert mode == "440 root users", f"the netrc is '{mode}', expected '440 root users'"

      with subtest("nix is pointed at that netrc"):
          netrc_setting = machine.succeed("nix config show netrc-file").strip()
          assert netrc_setting == "/run/secrets/rendered/attic_netrc", \
              f"nix reads its credentials from '{netrc_setting}'"
          machine.succeed(f"test -f {netrc_setting}")

      with subtest("the secret nix options are included into the daemon's configuration"):
          mode = ownership("nixExtraSecretOptions")
          assert mode == "440 root users", f"the extra nix options are '{mode}', expected '440 root users'"
          # read back through nix itself: this only holds if the `!include` in nix.conf resolved and was parsed
          timeout = machine.succeed("nix config show connect-timeout").strip()
          assert timeout == "7", \
              f"connect-timeout is '{timeout}', so the secret options file was not included"

      with subtest("the git askpass template carries the codeberg credentials"):
          askpass = secret("rendered/git-askpass")
          assert "username=${secretValues.codebergUser}" in askpass, f"no username in the askpass file: {askpass}"
          assert "password=${secretValues.codebergPat}" in askpass, f"no password in the askpass file: {askpass}"

      (_, failed) = machine.systemctl("--failed --quiet")
      machine.log(f"systemctl --failed output: {failed}")
      assert "" == failed, "Expected no failed units and got: " + failed
    '';
}
