{ config, pkgs, lib, setup, ... }:

let
  clone_script = import ./clone-script.nix { inherit pkgs; };
in
{
  systemd = {
    services = {
      clone-vimfiles = {
        description = "Clone vimfiles into ~/.vim if missing";
        wantedBy = [ "multi-user.target" ];

        unitConfig = {
          ConditionPathExists = "!/home/${setup.user}/.vim";
          After = [ "network-online.target" ];
          Wants = [ "network-online.target" ];
          RequiresMountsFor = [ "/home/${setup.user}" ];
        };

        serviceConfig = {
          Type = "oneshot";
          User = setup.user;
          WorkingDirectory = "/home/${setup.user}";
          ExecStart = let
            home = "/home/${setup.user}";
            repo="giggio/vimfiles.git";
          in ''
            ${clone_script}/bin/clone "https://github.com/${repo}" "${home}/.vim" --symlink "${home}/.config/nvim" --private-git-origin "git@github.com:${repo}"
          '';
        };
      };
      clone-nixos-config = let
          clone_script = import ./clone-script.nix { inherit pkgs; };
          home = "/home/${setup.user}";
          destination_dir = "/home/${setup.user}/.config/nixos";
          https_repo="https://github.com/giggio/nixos_serverbase.git";
          ssh_repo="git@github.com:giggio/nixos_serverbase.git";
        in {
        description = "Clone NixOS config ~/.config/nixos if missing";
        wantedBy = [ "multi-user.target" ];

        unitConfig = {
          ConditionPathExists = "!${destination_dir}";
          After = [ "network-online.target" ];
          Wants = [ "network-online.target" ];
          RequiresMountsFor = [ "/home/${setup.user}" ];
        };

        serviceConfig = {
          Type = "oneshot";
          ExecStart = ''
            ${clone_script}/bin/clone "${https_repo}" "${destination_dir}" \
            --private-git-origin "${ssh_repo}" \
            --https-user-file "${config.sops.secrets."gh_repo_clone/user".path}" \
            --https-password-file "${config.sops.secrets."gh_repo_clone/pat".path}" \
            --chown "${setup.user}"
          '';
        };
      };
    };
  };
}
