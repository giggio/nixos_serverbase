{ config, ... }:

{
  sops = {
    defaultSopsFile = ./secrets/shared.yaml;
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
