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
    };
  };
}
