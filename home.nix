{ config, pkgs, lib, inputs, setup, ... }:

rec {
  programs = {
    gpg = {
      enable = true;
      publicKeys = [
        {
          source = ./gpg_giggio.pub; # https://links.giggio.net/pgp
          trust = "ultimate";
        }
      ];
    };

  };
  home = {
    username = "giggio";
    homeDirectory = "/home/" + home.username;
    stateVersion = "25.11"; # Check if there are state version changes before changing this fiels: https://nix-community.github.io/home-manager/release-notes.xhtml
    preferXdgDirectories = true;
    # packages = import ./pkgs.nix { inherit config; inherit pkgs; inherit pkgs-stable; inherit lib; inherit setup; };

    shell = {
      enableBashIntegration = true;
    };

    # Home Manager can also manage your environment variables through
    # 'sessionVariables'. If you don't want to manage your shell through Home
    # Manager then you have to manually source 'hm-session-vars.sh' located at
    #  ~/.nix-profile/etc/profile.d/hm-session-vars.sh
    sessionPath = [
      "$HOME/.local/bin"
    ];
  };
}
