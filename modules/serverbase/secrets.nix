{ config, lib, ... }:

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
    };
    secrets = {
      "codeberg_repo_clone/user" = { };
      "codeberg_repo_clone/pat" = { };
      "attic_server" = { };
      "attic_token" = { };
    };
    templates.attic_netrc = {
      content = ''
        machine ${config.sops.placeholder.attic_server}
        password ${config.sops.placeholder.attic_token}
      '';
      mode = "0440";
      group = "users";
    };
  };
}
