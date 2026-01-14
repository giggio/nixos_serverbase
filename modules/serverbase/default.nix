{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:

let
  fenix = inputs.fenix;
in
{
  imports = [
    ../../cachix.nix # ugly loading from the root folder, can we do something about it?
    ./clone-config.nix
    ./secrets.nix
    ./options.nix
  ];

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    users.${config.setup.username} = ./home-manager/home.nix;
    extraSpecialArgs = { inherit inputs; };
    sharedModules = [
      ./options.nix
      { setup.username = config.setup.username; }
    ];
  };

  nixpkgs.config.allowUnfree = false;
  nixpkgs.overlays = [
    (
      _: super:
      let
        pkgs = fenix.inputs.nixpkgs.legacyPackages.${super.system};
      in
      fenix.overlays.default pkgs pkgs
    ) # rust toolchain
    (final: prev: (import ./pkgs/default.nix { pkgs = prev; }))
  ];

  nix = {
    settings.experimental-features = [
      "nix-command"
      "flakes"
    ];
  };

  boot = {
    initrd = {
      kernelModules = [
        # allows mounting of USB storage so that secrets can be stored there
        "usb_storage"
        "uas"
        "sd_mod"
        "xhci_pci"
        "ehci_pci"
      ];
      availableKernelModules = {
        # allows file systems on initrd
        vfat = true;
        ext4 = true;
        fuse = true;
        nls_cp437 = true;
        nls_iso8859_1 = true;
        iso9660 = true;
      };
      extraFiles."/bin/install_sops_key".source =
        (pkgs.writeShellApplication {
          name = "install-sops-key.sh";
          runtimeInputs = with pkgs; [
            coreutils
            bashInteractive
            util-linux
            procps
            iproute2
            ncurses
            python3
          ];
          text = (builtins.readFile ./scripts/install-sops-key.sh);
        }).overrideAttrs
          (oldAttrs: {
            buildCommand = oldAttrs.buildCommand + ''
              ln -s "${./scripts/initrd-nice-bash.sh}" "$out/bin/initrd-nice-bash.sh"
            '';
          });
      postMountCommands = ''
        # run the script we placed into the initrd
        if [ -x /bin/install_sops_key/bin/install-sops-key.sh ]; then
          ${pkgs.bashInteractive}/bin/bash /bin/install_sops_key/bin/install-sops-key.sh || true
        fi
      '';
    };
    loader = {
      systemd-boot.enable = lib.mkDefault false; # using grub and not UEFI
      timeout = lib.mkForce 10;
    };
  };

  networking = {
    firewall.enable = true;
    hostName = config.setup.derivedHostName;
    wireless.enable = false; # enables/disables wireless support via wpa_supplicant.
    useNetworkd = true;
    networkmanager.enable = lib.mkForce false; # using systemd-networkd
    useDHCP = lib.mkDefault true;
  };

  systemd = {
    network = {
      enable = true;
      wait-online.enable = true;
      networks = {
        "01-docker" = {
          matchConfig.Name = "docker*";
          extraConfig = ''
            [Link]
            Unmanaged=yes
          '';
        };
        "01-wlan0" = {
          matchConfig.WLANInterfaceType = "station";
          linkConfig = {
            ActivationPolicy = "down";
          };
          extraConfig = ''
            [Link]
            Unmanaged=yes
          '';
        };
      };

    };
    user.tmpfiles.enable = true;
  };

  time.timeZone = "America/Sao_Paulo";

  i18n = {
    defaultLocale = "en_US.UTF-8";
    extraLocaleSettings = {
      LC_ADDRESS = "en_US.UTF-8";
      LC_IDENTIFICATION = "en_US.UTF-8";
      LC_MEASUREMENT = "en_US.UTF-8";
      LC_MONETARY = "en_US.UTF-8";
      LC_NAME = "en_US.UTF-8";
      LC_NUMERIC = "en_US.UTF-8";
      LC_PAPER = "en_US.UTF-8";
      LC_TELEPHONE = "en_US.UTF-8";
      LC_TIME = "en_US.UTF-8";
    };
  };

  users.users.${config.setup.username} = {
    hashedPassword = "$y$j9T$uFrz8gHZsyL7Jo1iCC/ky.$lVYuZPrYGtrxbP564V49AO.HraNu8fqRWVtiXLVrUkD"; # generate with: nix run nixpkgs#mkpasswd -- -m yescrypt
    isNormalUser = true;
    description = "Giovanni Bassi";
    extraGroups = [
      "networkmanager"
      "wheel"
      "docker"
    ];
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCv/c4C2RbcY9phczEe980HpYJJPAtLJ14cBZPk6y3yhEVIISCaUGAfIcqFRcpA59xeyNnpbyvuuYNSrBSMiFFeYdLxw++9C7LAXKCODetAZsae+qkWkdO6aw3yVF9I4vmGaN7xfroQlodfX2u0tQ1MFxhmjxnBvV14kPsxlAlWFGKE9Hx9+HMRaNi0tw+N5QGfx33wSJ5wV+Q0xunM54226WeEtXO7InbsLySHCFaV0A8GW41bjrt5Q/DNmYAOgiezR1vVz81RxSzsGc0v5hVmwdadNPBvXhBoKvYTpooXILdHvKyNNIhUMEOS6aA5HooTwcExqosMp/xyFBVqpWjnKXzP7tzvTLu7W2GyHfBcoYgk5n7/PYvgnPvpx/G0rVDMjDYz2xchi6S8Qf4isj5brnLuXSUUcB2P3pG94epajIml9HZri3P+UaueAYb6F1CJttZdZu07sGkGww1GxRBv0IlHe61/yo7ZiWjOyFfTMn5BdyNjCy3bKuGAmNhCy3aBzOoDKrLfEDkWHMRZ4ypDsCqPcLBarhgQD0qArAd3lMcWvaiBASDkNonATQ6Bvv0udm8XCpc0yeUQ4VLi1QaUHTKCE4LfL8tBJZyGdWJevnP0v+ojf+NpW7EzqypzQerP3jTzHFOfTp2zKJ+R/oJ7ZQniwt6yUvXhQ9POW+aQcQ== openpgp:0x2E6F4761"
    ];
  };

  environment.systemPackages = with pkgs; [
    # search with: nix search wget
    gnupg
    kitty # to add Kitty's terminfo
    neovim
    wget
    eza
    delta
    fzf
    githooks # Simple Git hooks manager https://github.com/gabyx/githooks
    htop
    mylua # see pkgs/default.nix
    gnumake
    cachix
    # rust-toolchain-fenix # see pkgs/default.nix # commented out, takes too long to build, will add back if needed
    tree-sitter # An incremental parsing system for programming tools https://github.com/tree-sitter/tree-sitter
    marksman # Write Markdown with code assist and intelligence in the comfort of your favourite editor https://github.com/artempyanykh/marksman/
    markdownlint-cli2 # Fast, flexible, configuration-based command-line interface for linting Markdown/CommonMark files with the markdownlint library https://github.com/DavidAnson/markdownlint-cli2
    nixd # Nix language server https://github.com/nix-community/nixd/tree/main
    ripgrep # Line-oriented search tool that recursively searches your current directory for a regex pattern https://github.com/BurntSushi/ripgrep
    fd # Simple, fast and user-friendly alternative to find https://github.com/sharkdp/fd
    procs # A modern replacement for ps written in Rust https://github.com/dalance/procs
    python3
    gcc
    file
    tree
    bat
    jq
  ];

  environment = {
    etc = {
      "issue.d/extra.issue".text = ''
        NixOS \v
        \e{green}Machine:\e{reset} \n
        \e{green}IP:\e{reset} \4
        \e{green}Today is:\e{reset} \d \t
      '';
      "profile.d/xdg_dirs_extra.sh".source = ./scripts/xdg_dirs_extra.sh;
    };
    extraInit = ''
      # read extra profile files in /etc/profile.d/
      if [ -d /etc/profile.d ]; then
        for i in /etc/profile.d/*.sh; do
          if [ -r $i ]; then
            . $i
          fi
        done
        unset i
      fi
    '';
  };

  programs = {
    neovim = {
      enable = true;
      defaultEditor = true;
    };
    git.enable = true;
  };

  services = {
    openssh = {
      enable = true;
      settings = {
        StreamLocalBindUnlink = "yes";
      };
    };
    logind.settings.Login.KillUserProcesses = true;
  };

  virtualisation.docker.enable = true;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "25.11"; # Did you read the comment?

}
