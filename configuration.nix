# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, lib, setup, ... }:

let
  foo = 1;
in
{
  imports =
    [
      # Include the results of the hardware scan.
      # ./hardware-configuration.nix
      # ./clone-config.nix
    ] ++ lib.lists.optionals (setup.virtualbox) [
      ./vm.nix
    ];

  nixpkgs.config.allowUnfree = false;
  nixpkgs.overlays = [
    (final: prev: (import ./pkgs/default.nix { pkgs = prev; }))
  ];

  nix = {
    settings.experimental-features = [ "nix-command" "flakes" ];
  };

  boot = {
    loader = {
      systemd-boot.enable = false; # using grub and not UEFI
      timeout = 5;
    };
  };

  networking = {
    hostName = "pitest";
    wireless.enable = false;  # enables/disables wireless support via wpa_supplicant.
    useNetworkd = true;
    networkmanager.enable = false; # using systemd-networkd
    useDHCP = lib.mkDefault true;
  };

  systemd = {
    network = {
      enable = true;
      wait-online.enable = true;
      networks = {
        "docker" = {
          matchConfig.Name = "docker*";
          extraConfig = ''
            [Link]
            Unmanaged=yes
          '';
        };
      };

    };
    services.renderIssue = {
      description = "Render login issue (IP)";
      wantedBy = [ "multi-user.target" ];
      before = [ "getty.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = ''
          ${pkgs.bash}/bin/bash -c '
          mkdir -p /run/issue.d
          # printf "IP: %s\n" "$(${pkgs.iproute2}/bin/ip -4 route get 1.1.1.1 2>/dev/null | ${pkgs.gawk}/bin/awk "{print \\$7; exit}")" \
            # > /run/issue.d/90-ip.issue
          echo -e "\e[32mIP: $(${pkgs.iproute2}/bin/ip -4 route get 1.1.1.1 | ${pkgs.gawk}/bin/awk '{print $7}')\e[0m\n" \
            > /run/issue.d/90-ip.issue
          '
        '';
      };
    };
    user = {
      tmpfiles = {
        enable = true;
        users.giggio.rules = [
          "d /run/user/1000/gnupg 0700 1000 1000 -"
        ];
      };
    };
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

  users.users.giggio = {
    hashedPassword = "$y$j9T$uFrz8gHZsyL7Jo1iCC/ky.$lVYuZPrYGtrxbP564V49AO.HraNu8fqRWVtiXLVrUkD"; # generate with: nix run nixpkgs#mkpasswd -- -m yescrypt
    isNormalUser = true;
    description = "Giovanni Bassi";
    extraGroups = [ "networkmanager" "wheel" "docker" ];
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCv/c4C2RbcY9phczEe980HpYJJPAtLJ14cBZPk6y3yhEVIISCaUGAfIcqFRcpA59xeyNnpbyvuuYNSrBSMiFFeYdLxw++9C7LAXKCODetAZsae+qkWkdO6aw3yVF9I4vmGaN7xfroQlodfX2u0tQ1MFxhmjxnBvV14kPsxlAlWFGKE9Hx9+HMRaNi0tw+N5QGfx33wSJ5wV+Q0xunM54226WeEtXO7InbsLySHCFaV0A8GW41bjrt5Q/DNmYAOgiezR1vVz81RxSzsGc0v5hVmwdadNPBvXhBoKvYTpooXILdHvKyNNIhUMEOS6aA5HooTwcExqosMp/xyFBVqpWjnKXzP7tzvTLu7W2GyHfBcoYgk5n7/PYvgnPvpx/G0rVDMjDYz2xchi6S8Qf4isj5brnLuXSUUcB2P3pG94epajIml9HZri3P+UaueAYb6F1CJttZdZu07sGkGww1GxRBv0IlHe61/yo7ZiWjOyFfTMn5BdyNjCy3bKuGAmNhCy3aBzOoDKrLfEDkWHMRZ4ypDsCqPcLBarhgQD0qArAd3lMcWvaiBASDkNonATQ6Bvv0udm8XCpc0yeUQ4VLi1QaUHTKCE4LfL8tBJZyGdWJevnP0v+ojf+NpW7EzqypzQerP3jTzHFOfTp2zKJ+R/oJ7ZQniwt6yUvXhQ9POW+aQcQ== openpgp:0x2E6F4761"
    ];
    packages = with pkgs; [
    ];
  };

  environment.systemPackages = with pkgs; [ # search with: nix search wget
    gnupg
    kitty # to add Kitty's terminfo
    neovim
    wget
    eza
    delta
    fzf
    githooks # Simple Git hooks manager https://github.com/gabyx/githooks
    mylua # see pkgs/default.nix
  ];

  programs = {
    neovim = {
      enable = true;
      defaultEditor = true;
    };
    git.enable = true;
    # gnupg.agent.enable = true; # so that the socket paths at /run/user/1000/gnupg/ are created
  };

  services = {
    openssh.enable = true;
    logind.settings.Login.KillUserProcesses = true;
  };

  virtualisation.docker.enable = true;

  networking.firewall.allowedTCPPorts = [ 22 ];

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "25.11"; # Did you read the comment?

}
