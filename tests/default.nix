{
  boot-test = ./boot.nix;
  base-packages = ./base-packages.nix;
  base-users-ssh = ./base-users-ssh.nix;
  base-networking = ./base-networking.nix;
  base-nix-env = ./base-nix-env.nix;
  clone-config = ./clone-config.nix;
  secrets-sops = ./secrets-sops.nix;
  machines-boot = ./machines-boot.nix;
  home-manager = ./home-manager.nix;
  helpers = ./helpers.nix;
  custom-packages = ./custom-packages.nix;
  traefik-provider = ./traefik-provider.nix;
  gmktec1-docker = ./gmktec1-docker.nix;
}
