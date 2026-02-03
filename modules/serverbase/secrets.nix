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
    };
  };
}
