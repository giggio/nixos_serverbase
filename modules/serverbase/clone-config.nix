{
  config,
  pkgs,
  lib,
  ...
}:

let
  clone_script = import ./clone-script.nix { inherit pkgs; };
  home = "/home/${config.setup.username}";
in
{
  options.setup = with lib; {
    vimFiles = {
      enable = mkEnableOption "Clone vimfiles enabled" // {
        default = true;
      };
      repo = mkOption {
        type = types.str;
        default = "giggio/vimfiles";
        example = literalExpression "{ repo = \"https://codeberg.org/giggio/vimfiles.git\"; }";
      };
      cloneDir = mkOption {
        type = types.str;
        default = "${home}/.vim";
        example = literalExpression "{ cloneDir = \"/home/giggio/.vim\"; }";
      };
      customRepoUrl = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = literalExpression "{ customRepoUrl = \"https://codeberg.org/giggio/vimfiles.git\"; }";
      };
      customPrivateRepoUrl = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = literalExpression "{ customPrivateRepoUrl  = \"git@codeberg.org:giggio/vimfiles.git\"; }";
      };
      usePrivateRepo = mkEnableOption "Set if private repo should be used" // {
        default = true;
      };
      symlinkDir = mkOption {
        type = types.nullOr types.str;
        default = "${home}/.config/nvim";
        example = literalExpression "{ symlinkDir = \"/home/giggio/.config/nvim\"; }";
      };
    };
    nixosConfig = {
      enable = mkEnableOption "Clone nixOS configuration enabled" // {
        default = true;
      };
      repo = mkOption {
        type = types.str;
        default = "giggio/nixos_serverbase";
        description = "The repository to clone the configuration from";
        example = literalExpression ''{ repo = "giggio/nixos_serverbase"; }'';
      };
      cloneDir = mkOption {
        type = types.str;
        default = "${home}/.config/nixos";
        example = literalExpression ''{ cloneDir = "/home/giggio/.config/nixos"; }'';
      };
      customRepoUrl = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = literalExpression "{ customRepoUrl = \"https://codeberg.org/giggio/vimfiles.git\"; }";
      };
      customPrivateRepoUrl = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = literalExpression "{ customPrivateRepoUrl  = \"git@codeberg.org:giggio/vimfiles.git\"; }";
      };
      usePrivateRepo = mkEnableOption "Set if private repo should be used" // {
        default = true;
      };
      useCredentials = mkEnableOption "Set if credentials should be used";
    };
  };
  config = {
    systemd = {
      services = {
        clone-vimfiles =
          let
            clone_dir = config.setup.vimFiles.cloneDir;
            repoUrl =
              if config.setup.vimFiles.customRepoUrl != null then
                config.setup.vimFiles.customRepoUrl
              else
                "https://codeberg.org/${config.setup.vimFiles.repo}.git";
            privateRepoUrl =
              if config.setup.vimFiles.customPrivateRepoUrl != null then
                config.setup.vimFiles.customPrivateRepoUrl
              else
                "git@codeberg.org:${config.setup.vimFiles.repo}.git";
          in
          {
            description = "Clone vimfiles into ~/.vim if missing";
            wantedBy = [ "multi-user.target" ];
            path = [ pkgs.coreutils ];

            unitConfig = {
              ConditionPathExists = "!${clone_dir}";
              After = [ "network-online.target" ];
              Wants = [ "network-online.target" ];
              RequiresMountsFor = [ home ];
              StartLimitIntervalSec = 600;
              StartLimitBurst = 10;
            };

            serviceConfig = {
              Type = "oneshot";
              Restart = "on-failure";
              RestartSec = 30;
            };

            script = ''
              echo "Cloning vimfiles into ${clone_dir} using repo ${repoUrl}"
              echo "Private repo is ${privateRepoUrl} (using private repo: ${
                if config.setup.vimFiles.usePrivateRepo then "true" else "false"
              })"
              echo "Symlink dir is ${toString config.setup.vimFiles.symlinkDir})"
              echo "Changing ownership to ${config.setup.username}"
              ${clone_script}/bin/clone "${toString repoUrl}" "${clone_dir}" \
              ${if config.setup.vimFiles.symlinkDir != null then ''--symlink "${home}/.config/nvim"'' else ""} \
              ${
                if config.setup.vimFiles.usePrivateRepo then ''--private-git-origin "${privateRepoUrl}"'' else ""
              } \
              --chown "${config.setup.username}"
            '';
          };
        clone-nixos-config =
          let
            clone_dir = config.setup.nixosConfig.cloneDir;
            repoUrl =
              if config.setup.nixosConfig.customRepoUrl != null then
                config.setup.nixosConfig.customRepoUrl
              else
                "https://codeberg.org/${config.setup.nixosConfig.repo}.git";
            privateRepoUrl =
              if config.setup.nixosConfig.customPrivateRepoUrl != null then
                config.setup.nixosConfig.customPrivateRepoUrl
              else
                "git@codeberg.org:${config.setup.nixosConfig.repo}.git";
            git_askpass = pkgs.writeShellScript "git_askpass" ''
              source "${config.sops.templates."git-askpass".path}"
              case "$1" in
                *Username*) echo "$username" ;;
                *Password*) echo "$password" ;;
              esac
            '';
          in
          {
            description = "Clone NixOS config ~/.config/nixos if missing";
            wantedBy = [ "multi-user.target" ];
            path = [ pkgs.coreutils ];

            unitConfig = {
              ConditionPathExists = "!${clone_dir}";
              After = [ "network-online.target" ];
              Wants = [ "network-online.target" ];
              RequiresMountsFor = [ home ];
              StartLimitIntervalSec = 600;
              StartLimitBurst = 10;
            };

            serviceConfig = {
              Type = "oneshot";
              Restart = "on-failure";
              RestartSec = 30;
            };
            script = ''
              echo "Cloning nixosConfig into ${clone_dir} using repo ${repoUrl}"
              echo "Private repo is ${privateRepoUrl} (using private repo: ${
                if config.setup.nixosConfig.usePrivateRepo then "true" else "false"
              })"
              echo "Changing ownership to ${config.setup.username}"
              echo "Using credentials: ${if config.setup.nixosConfig.useCredentials then "true" else "false"}"
              ${clone_script}/bin/clone "${repoUrl}" "${clone_dir}" \
              ${
                if config.setup.nixosConfig.usePrivateRepo then ''--private-git-origin "${privateRepoUrl}"'' else ""
              } \
              ${if config.setup.nixosConfig.useCredentials then ''--git-askpass-file "${git_askpass}"'' else ""} \
              --chown "${config.setup.username}"
            '';
          };
      };
    };
    sops.templates."git-askpass" = {
      content = ''
        username=${config.sops.placeholder."codeberg_repo_clone/user"}
        password=${config.sops.placeholder."codeberg_repo_clone/pat"}
      '';
    };
  };
}
