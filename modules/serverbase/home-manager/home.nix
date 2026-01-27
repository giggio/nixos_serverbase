{
  config,
  pkgs,
  lib,
  ...
}:

let
  # todo: move shellSessionVariables somewhere else when https://github.com/nix-community/home-manager/issues/5474 is fixed
  shellSessionVariables = {
    DOCKER_BUILDKIT = "1";
    FZF_DEFAULT_COMMAND = "'fd --type file --color=always --exclude .git'";
    FZF_DEFAULT_OPTS = "--ansi";
    FZF_CTRL_T_COMMAND = ''"$FZF_DEFAULT_COMMAND"'';
  };
  homeDirectory = "/home/${config.setup.username}";
in
{
  imports = [ ];
  programs = {
    bash = {
      enable = true;
      initExtra = lib.mkMerge [
        ''
          # end of nix configuration

          # ending of .bashrc:

          if [ "$TERM" == "xterm-kitty" ]; then
            source "$(blesh-share)/ble.sh"
            eval "$(atuin init bash)"
          fi

          # end of .bashrc

          # beginning of configurations coming from other options, like gpg-agent, direnv and zoxide
        ''
        (lib.mkOrder 10000 ''
          # very end of .bashrc
          export PATH="$(printf '%s\n' "$HOME/.local/bin:$PATH" | tr ':' '\n' | awk '!seen[$0]++' | paste -sd: -)"
        '')
      ];
      profileExtra = ''
        # beginning of .profile
        umask 022
        if ! [ -v XDG_RUNTIME_DIR ]; then
          XDG_RUNTIME_DIR=/run/user/`id -u`/
          export XDG_RUNTIME_DIR
          if ! [ -d "$XDG_RUNTIME_DIR" ]; then
            mkdir -p "$XDG_RUNTIME_DIR"
            chmod 755 "$XDG_RUNTIME_DIR"
          fi
        fi
        # ending of .profile
      '';
      shellAliases = {
        ls = "ls --color=auto --hyperlink=always";
        dir = "dir --color=auto";
        vdir = "vdir --color=auto";
        grep = "grep --color=auto";
        fgrep = "fgrep --color=auto";
        egrep = "egrep --color=auto";
        ll = "eza --long --group --all --all --group-directories-first --hyperlink";
        la = "ls -A";
        l = "ls -CF";
        cls = "clear";
        add = "git add";
        st = "git status";
        log = "git log";
        ci = "git commit";
        push = "git push";
        pushf = "git push --force-with-lease";
        co = "git checkout";
        pull = "git pull";
        fixup = "git fixup";
        dif = "git diff";
        pushsync = "git push --set-upstream origin `git rev-parse --abbrev-ref HEAD`";
        "cd-" = "cd -";
        "cd.." = "cd ..";
        "cd..." = "cd ../..";
        "cd...." = "cd ../../..";
        cdr = "cd `git rev-parse --show-toplevel 2> /dev/null || echo '.'`";
        update = "sudo apt update; apt list --upgradable";
        upgrade = "apt list --upgradable; sudo apt upgrade -y; apt list --upgradable; [ -f /var/run/reboot-required ] && echo -e '\e[31mReboot required.\e[0m' || echo -e '\e[32mNo need to reboot.\e[0m'";
        http = "xh";
        vim = "nvim";
        vi = "nvim";
        cl = "tput clear";
      };
      shellOptions = [
        "histappend"
        "checkwinsize"
        "extglob"
        "globstar"
        "checkjobs"
      ];

      bashrcExtra =
        let
          bashSessionVariables = {
            # environment variables to add only to .bashrc
            PATH = "$HOME/.local/bin:$PATH"; # this is here so it is added before the other paths
            LUA_PATH = "\"${pkgs.mylua}/share/lua/5.1/?.lua;${pkgs.mylua}/share/lua/5.1/?/init.lua;$HOME/.luarocks/share/lua/5.1/?.lua;$HOME/.luarocks/share/lua/5.1/?/init.lua;$LUA_PATH;;\"";
            LUA_CPATH = "\"${pkgs.mylua}/lib/lua/5.1/?.so;$HOME/.luarocks/lib/lua/5.1/?.so;$LUA_CPATH;;\"";
          };
        in
        lib.concatStringsSep "\n" (
          lib.concatLists [
            [
              ''
                # beginning of .bashrc

                # Shell session variables:
              ''
            ]
            (lib.mapAttrsToList (k: v: "export ${k}=${v}") shellSessionVariables)
            [
              ''

                # Bash session variables:
              ''
            ]
            (lib.mapAttrsToList (k: v: "export ${k}=${v}") bashSessionVariables)
            [
              ''

                # beginning of .bashrc config
                unset MAILCHECK
                # If not running interactively, don't do anything
                [[ $- == *i* ]] || return
                # configure vi mode
                set -o vi
                bind '"jj":"\e"'
                tabs -4
                bind 'set completion-ignore-case on'
                source ${pkgs.complete-alias}/bin/complete_alias
                # make less more friendly for non-text input files, see lesspipe(1)
                [ -x /usr/bin/lesspipe ] && eval "$(SHELL=/bin/sh lesspipe)"

                # beginning of nix configuration
              ''
            ]
          ]
        );

    };
    gpg = {
      enable = true;
      publicKeys = [
        {
          source = ./gpg_giggio.pub; # https://links.giggio.net/pgp
          trust = "ultimate";
        }
      ];
    };

    starship.enable = true;

    direnv = {
      enable = true;
      nix-direnv.enable = true;
      config = {
        global = {
          hide_env_diff = true;
        };
      };
    };

    zoxide = {
      enable = true;
    };

    atuin = {
      enable = true;
      enableBashIntegration = false; # only for TERM=xterm-kitty
      daemon.enable = false;
      settings = {
        # https://docs.atuin.sh/configuration/config/
        search_mode = "skim";
        workspaces = true;
        inline_height = 0;
        enter_accept = true;
        smart_sort = true;
      };
    };

  };
  home = {
    username = config.setup.username;
    inherit homeDirectory;
    stateVersion = "25.11"; # Check if there are state version changes before changing this fiels: https://nix-community.github.io/home-manager/release-notes.xhtml
    preferXdgDirectories = true;

    packages = with pkgs; [
      (blesh.overrideAttrs {
        # only enabled for TERM=xterm-kitty
        version = "nightly-20250209+4338bbf";
        src = fetchzip {
          url = "https://github.com/akinomyoga/ble.sh/releases/download/nightly/ble-nightly-20260125+32bb63d.tar.xz";
          sha256 = "sha256-11hfYAIBslBGmCj84lNv57DhBzUre+7hreMSz2YGzVQ=";
        };
      })
    ];

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
    sessionVariables = {
      # this goes into ~/.nix-profile/etc/profile.d/hm-session-vars.sh, which is
      # loaded by .profile, and so only reloads if we logout and log back in
      TMP = "/tmp";
      TEMP = "/tmp";
      XDG_DATA_HOME = "\${XDG_DATA_HOME:-$HOME/.local/share}";
      XDG_STATE_HOME = "\${XDG_STATE_HOME:-$HOME/.local/state}";
      XDG_CACHE_HOME = "\${XDG_CACHE_HOME:-$HOME/.cache}";
      IS_SERVER = "1"; # used by vim/nvim to configure a leaner environment
    };
    sessionVariablesExtra = lib.mkOrder 2000 ''
      # this is from sessionVariablesExtra, and is loaded at the very end hm-session-vars.sh
    '';

    file = {
      ".gitconfig".source = ./.gitconfig;
      ".hushlogin".text = "";
      ".tmux.conf".text = ''
        set -g default-terminal "screen-256color"
        set-option -g default-shell /bin/bash
        set -g history-limit 10000
        source "$HOME/.nix-profile/share/tmux/powerline.conf"
        set -g status-bg colour233
        set-option -g status-position top
        set -g mouse

        # Smart pane switching with awareness of vim splits
        bind -n C-h run "(tmux display-message -p '#{pane_current_command}' | grep -iqE '(^|\/)g?(view|vim?)(diff)?$' && tmux send-keys C-h) || tmux select-pane -L"
        bind -n C-j run "(tmux display-message -p '#{pane_current_command}' | grep -iqE '(^|\/)g?(view|vim?)(diff)?$' && tmux send-keys C-j) || tmux select-pane -D"
        bind -n C-k run "(tmux display-message -p '#{pane_current_command}' | grep -iqE '(^|\/)g?(view|vim?)(diff)?$' && tmux send-keys C-k) || tmux select-pane -U"
        bind -n C-l run "(tmux display-message -p '#{pane_current_command}' | grep -iqE '(^|\/)g?(view|vim?)(diff)?$' && tmux send-keys C-l) || tmux select-pane -R"
        # bind -n C-\ run "(tmux display-message -p '#{pane_current_command}' | grep -iqE '(^|\/)g?(view|vim?)(diff)?$' && tmux send-keys 'C-\\') || tmux select-pane -l"
      '';
      ".inputrc".text = ''
        set bell-style none
      '';
      ".vimrc".text = "source ~/.vim/init.vim";
      ".local/bin/nr".source = ./bin/nr;
    };

  };
  xdg = {
    configFile = {
      "starship.toml".source = ./config/starship.toml;
      "git".source = ./config/git;
      "blesh/init.sh".text = ''
        ble-import integration/zoxide
        ble-import integration/nix-completion.bash
        ble-import vim-airline
        bleopt vim_airline_theme=raven
        bleopt vim_airline_section_c=
        bleopt vim_airline_section_b=
        bleopt vim_airline_section_x=
        bleopt vim_airline_section_y=
        # ctrl+c to discard line
        ble-bind -m vi_imap -f 'C-c' discard-line
        ble-bind -m vi_nmap -f 'C-c' discard-line
      '';
    };
  };

  systemd = {
    user = {
      services = { };
      tmpfiles.rules = [
        "d /run/user/1000/ 0700 1000 1000 -"
        "d /run/user/1000/gnupg 0700 1000 1000 -"
        "d ${homeDirectory}/.cache/git/credential/ 0700 ${config.setup.username} - -"
      ];
    };
  };
}
