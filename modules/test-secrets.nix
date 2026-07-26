{ lib }:

# Test-only sops fixtures. Every secret a machine declares is encrypted to the servers' key, which no test has, so a test
# node that boots the real module set cannot decrypt a single one of them - and since sops-nix fails activation when a
# secret is missing, that means it cannot boot at all. What follows replaces the whole secret set with a fixture
# generated and encrypted while the check builds, so a test never needs a key, never needs plaintext committed anywhere,
# and never has to be updated by hand when a machine gains a secret.
#
# The names come from the caller (see mkChecks' `testNodes.fakeSecrets`), never from the node's own configuration:
# deriving them from `config.sops.secrets` while also defining `config.sops.secrets` is an infinite recursion.
let
  # Test-only age identity. It exists to encrypt the fixtures below and nothing else; no real secret is, or ever should
  # be, encrypted to it. It is committed on purpose, so that the checks need no setup to run.
  publicKey = "age1seqqa058acupwts8neefs5vdu8lwpz7hdyry000vd0xu5dp7nefqqc76wx";
  privateKey = "AGE-SECRET-KEY-1MTQ3WT0F43GESK4XAP9Z2VLJ0W9TLR4UUL0EYX3HSPN95P4HJJ5SGCLFUM";
  keyPath = "/run/test-age-key";

  # Secrets that cannot be an arbitrary string without breaking the machine that reads them. Callers add their own
  # through `values`; what is listed here is only what this repository's own modules require.
  defaultValues = {
    # ends up in nix.conf through an `!include`, so it has to parse as a nix setting
    nixExtraSecretOptions = "connect-timeout = 7\n";
  };

  # Secrets this repository declares with `format = "binary"`: the file *is* the value, so they cannot live in the
  # shared structured fixture and get one encrypted file each.
  defaultBinaryNames = [ "nixExtraSecretOptions" ];
in
{
  # names        - every secret the node declares, as sops-nix names them ("a/b" addresses a nested key)
  # values       - plaintext for the ones whose shape matters; anything else gets a value derived from its name
  # binaryNames  - names declared with `format = "binary"`, encrypted one file each instead of into the fixture
  mkFakeSecrets =
    {
      names,
      values ? { },
      binaryNames ? defaultBinaryNames,
    }:
    { pkgs, ... }:
    let
      allValues = defaultValues // values;
      valueOf = name: allValues.${name} or "test-${builtins.replaceStrings [ "/" ] [ "-" ] name}";

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
            export SOPS_AGE_RECIPIENTS=${publicKey}
            sops --encrypt --input-type ${format} --output-type ${format} "$textPath" > $out
          '';

      structuredNames = builtins.filter (name: !(builtins.elem name binaryNames)) names;
      # The fixture is written as JSON and handed to sops as YAML. JSON, because the values are arbitrary strings -
      # passwords, PEM blocks, tokens with leading zeroes - and it has exactly one way to quote all of them, where
      # hand-written YAML has several and a wrong guess yields a fixture that decrypts to the wrong type. YAML on the
      # sops side (JSON being a subset of it) because sops-install-secrets only walks a nested key path through the type
      # its YAML parser produces; against a file it decoded as JSON, every `a/b` secret fails with "key 'a' does not
      # refer to a dictionary".
      fixture = encrypt {
        name = "test-secrets.yaml";
        format = "yaml";
        text = builtins.toJSON (
          lib.foldl' (
            tree: name: lib.recursiveUpdate tree (lib.setAttrByPath (lib.splitString "/" name) (valueOf name))
          ) { } structuredNames
        );
      };

      binaryFixtures = lib.genAttrs binaryNames (
        name:
        encrypt {
          name = "test-secret-${builtins.replaceStrings [ "/" ] [ "-" ] name}";
          format = "binary";
          text = valueOf name;
        }
      );
    in
    {
      sops = {
        # the fixtures are only encrypted when their derivation is built, so there is nothing for sops-nix to inspect at
        # evaluation time. Dropping the check is safe here and only here: what it guards against - committing a
        # plaintext secret - cannot happen to a file that is generated.
        validateSopsFiles = false;
        age.keyFile = lib.mkForce keyPath;
        defaultSopsFile = lib.mkForce fixture;
        defaultSopsFormat = lib.mkForce "yaml";
        secrets =
          lib.genAttrs structuredNames (name: {
            sopsFile = lib.mkForce fixture;
            format = lib.mkForce "yaml";
            # The fixture is built from the attribute names, but sops-nix looks a secret up by its `key`, which a
            # machine is free to point somewhere else - several secrets here are named after the service that reads
            # them and keyed on the bare name inside that service's own file. A single key it cannot find is not a
            # partial failure: sops-install-secrets rejects the whole manifest, /run/secrets is never created, and
            # every service on the machine then fails on something that reads like its own bug - a missing
            # `EnvironmentFile=` surfaces as "Failed to spawn 'start-pre' task: No such file or directory".
            key = lib.mkForce name;
          })
          // lib.mapAttrs (_: file: {
            sopsFile = lib.mkForce file;
            format = lib.mkForce "binary";
          }) binaryFixtures;
      };

      # On a server the key is installed from a USB stick during boot; a test has no operator to plug one in, so it is
      # laid down from the store instead. sops-nix refuses a keyFile that is itself in the store, and rightly so - the
      # store is world-readable - hence the copy, ordered before the secrets are decrypted.
      system.activationScripts = {
        testAgeKey = "install -D -m 0400 ${pkgs.writeText "test-age-key" privateKey} ${keyPath}";
        setupSecrets.deps = [ "testAgeKey" ];
      };
    };
}
