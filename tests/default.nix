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
  flake-matrix = ./flake-matrix.nix;
  custom-packages = ./custom-packages.nix;
  traefik-provider = ./traefik-provider.nix;
  gmktec1-docker = ./gmktec1-docker.nix;
  opi4pro-kernel-config = ./opi4pro-kernel-config.nix;
  clevis-unlock = ./clevis-unlock.nix;
  encrypted-state = ./encrypted-state.nix;
}
