{ lib, ... }:

{
  sops = {
    # mkDefault, and this is the hinge of the whole arrangement: the secrets checked into this public
    # repository are placeholders that only exist so a bare machine builds and installs standalone.
    # A superproject with real credentials points this at its own file - encrypted to its own machines'
    # keys, which never appear here - and every secret declared below keeps working unchanged, because
    # only the file they resolve to differs, never their names.
    defaultSopsFile = lib.mkDefault ./secrets/shared.yaml;
    age = {
      keyFile = "/etc/sops/age/server.agekey";
      generateKey = false;
      # sops-nix's defaults also turn the SSH host keys into identities: ed25519 into age, RSA into GPG. None was
      # ever a recipient, but they sit on unencrypted roots, and making one a recipient later would let a stolen
      # card open whatever it was added to. The machine's identity is the key file above, and nothing else.
      sshKeyPaths = [ ];
    };
    gnupg.sshKeyPaths = [ ];
    secrets = {
      # Forge-agnostic by name, deliberately: it was `codeberg_repo_clone` until 2026-09-19, which described the
      # forge that happened to host the repository rather than what the credential is for, and the configuration
      # repositories have since moved to a self-hosted Forgejo.
      #
      # NOTHING READS THIS TODAY and it is kept anyway. `setup.nixosConfig.useCredentials` defaults to false, and
      # the clone unit only runs when the clone directory is missing, so on an existing machine the template is
      # built and never opened. It stays because the mechanism works and is the only thing standing between a
      # private configuration repository and a machine that cannot install itself - deleting it would be free
      # today and expensive on the day the repository stops being readable anonymously.
      "config_repo_clone/user" = { };
      "config_repo_clone/pat" = { };
    };
  };
}

# The attic netrc used to be assembled here, from `attic_server` and `attic_token`, and `nix.settings.netrc-file`
# in default.nix pointed at it. Both are gone as of 2026-09-19: the cache serves `nix-cache-info` anonymously with
# a 200, so nix needs no credential to substitute from it and the token was a standing secret on every machine
# paying for nothing. Pushing still needs one; the machines do not push.
#
# `extra-substituters` is untouched and still arrives through `nixExtraSecretOptions` - removing the CREDENTIAL is
# not the same as removing the CACHE, and a machine that stops substituting from it would rebuild the world.
#
# If the cache is ever made private again, this comes back together with `netrc-file`, and the symptom in the
# meantime is unambiguous: 401 Unauthorized from the substituter.
