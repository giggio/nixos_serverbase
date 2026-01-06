{ config, pkgs, lib, setup, ... }:

let
  clone_script = import ./clone-script.nix { inherit pkgs; };
in
{
  systemd = {
    services = {
      clone-vimfiles =
        let
          home = "/home/${config.setup.username}";
          clone_dir = "${home}/.vim";
          repo = "giggio/vimfiles.git";
        in
        {
          description = "Clone vimfiles into ~/.vim if missing";
          wantedBy = [ "multi-user.target" ];

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
            ExecStart = ''
              ${clone_script}/bin/clone "https://github.com/${repo}" "${clone_dir}" \
              --symlink "${home}/.config/nvim" \
              --private-git-origin "git@github.com:${repo}" \
              --chown "${config.setup.username}"
            '';
            Restart = "on-failure";
            RestartSec = 30;
          };
        };
      clone-nixos-config =
        let
          clone_script = import ./clone-script.nix { inherit pkgs; };
          home = "/home/${config.setup.username}";
          destination_dir = config.setup.nixosConfigDir;
          https_repo = "https://github.com/${config.setup.configRepo}.git";
          ssh_repo = "git@github.com:${config.setup.configRepo}.git";
        in
        {
          description = "Clone NixOS config ~/.config/nixos if missing";
          wantedBy = [ "multi-user.target" ];

          unitConfig = {
            ConditionPathExists = "!${destination_dir}";
            After = [ "network-online.target" ];
            Wants = [ "network-online.target" ];
            RequiresMountsFor = [ "/home/${config.setup.username}" ];
            StartLimitIntervalSec = 600;
            StartLimitBurst = 10;
          };

          serviceConfig = {
            Type = "oneshot";
            ExecStart = ''
              ${clone_script}/bin/clone "${https_repo}" "${destination_dir}" \
              --private-git-origin "${ssh_repo}" \
              --https-user-file "${config.sops.secrets."gh_repo_clone/user".path}" \
              --https-password-file "${config.sops.secrets."gh_repo_clone/pat".path}" \
              --chown "${config.setup.username}"
            '';
            Restart = "on-failure";
            RestartSec = 30;
          };
        };
    };
  };
}
