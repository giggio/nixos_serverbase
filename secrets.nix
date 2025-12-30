{
  sops = {
    defaultSopsFile = ./secrets/shared.yaml;
    age = {
      keyFile = "/etc/sops/age/server.agekey";
      generateKey = false;
    };
    secrets = {
      "gh_repo_clone/user" = {};
      "gh_repo_clone/pat" = {};
    };
  };
}
