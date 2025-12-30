{ config, pkgs, lib, setup, ... }:

let
  foo = 1;
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
          Environment = "HOME=/home/${setup.user} REPO=giggio/vimfiles.git";
          ExecStart = let
            clone_vimfiles = pkgs.writeShellApplication {
              name = "clone_vimfiles";
              runtimeInputs = (with pkgs; [ coreutils git ]);
              text = ''
                echo "Cloning vimfiles via HTTPS..."
                git clone --recurse-submodules "https://github.com/$REPO" "$HOME/.vim"
                echo "Cloning done, now removing $HOME/.config/nvim..."
                rm -rf "$HOME/.config/nvim"
                echo "Removal done, now symlinking to $HOME/.vim to $HOME/.config/nvim..."
                ln -s "$HOME/.vim" "$HOME/.config/nvim"
                cd "$HOME/.vim"
                echo "Switching origin to SSH..."
                git remote set-url origin "git@github.com:$REPO"
                git submodule sync
                echo "Done Switching."
              '';
            };
          in
            "${clone_vimfiles}/bin/clone_vimfiles";
        };
      };
    };
  };
}
