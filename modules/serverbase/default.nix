{
  config,
  pkgs,
  lib,
  ...
}:

{
  imports = [
    ../../cachix.nix # ugly loading from the root folder, can we do something about it?
    ./clone-config.nix
    ./hardware
    ./home/home.nix
    ./ipv6.nix
    ./secrets.nix
    ./sudo.nix
    ./services
    ./options.nix
  ];

  nixpkgs.config.allowUnfree = false;
  nixpkgs.overlays = import ./overlays.nix { };

  nix = {
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      trusted-public-keys = [
        "giggio:gA25EMS+ouiC1xzWOKP68b7ikEfjmXohUT1PZ6aNP5c="
      ];
    };
    extraOptions = ''
      !include ${config.sops.secrets.nixExtraSecretOptions.path}
    '';
  };

  sops.secrets.nixExtraSecretOptions = {
    # Named explicitly rather than falling back to defaultSopsFile, so it needs its own mkDefault to
    # stay overridable by a superproject. Same reasoning as secrets.nix: the real content is a private
    # cache address, which is a value and does not belong in a public repository.
    sopsFile = lib.mkDefault ./secrets/nix_extra_options.conf;
    format = "binary";
    mode = "0440";
    group = "users";
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

      systemd = {
        emergencyAccess = true;
        initrdBin = with pkgs; [
          coreutils
          bashInteractive
          util-linux
          procps
          iproute2
          ncurses
          python3
          which
          (pkgs.writeShellApplication {
            name = "install_sops_key";
            text = (builtins.readFile ./scripts/install-sops-key.sh);
          })
          (pkgs.writeShellApplication {
            name = "initrd_nice_bash";
            text = (builtins.readFile ./scripts/initrd-nice-bash.sh);
          })
        ];
        services.install_sops_key = {
          enable = !config.setup.isTest;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            # Which age key this machine looks for on the stick. `setup.hostName`, not
            # `networking.hostName`: the latter carries the dev/vm suffixes, and a gmktec1 dev VM must
            # pick up gmktec1's key rather than look for one that was never generated.
            Environment = "SOPS_KEY_HOSTNAME=${config.setup.hostName}";
            # route standard input/output directly to the boot console
            StandardInput = "tty";
            StandardOutput = "tty";
            StandardError = "tty";
            TTYPath = "/dev/console";
            TTYReset = true;
            TTYVHangup = true;
          };
          unitConfig.DefaultDependencies = "no";
          after = [ "initrd-fs.target" ];
          before = [ "initrd.target" ];
          wantedBy = [ "initrd.target" ];

          script = ''
            logger -t install_sops_key "Starting to search for sops key"
            if ! ${pkgs.bashInteractive}/bin/bash /bin/install_sops_key; then
              logger -t install_sops_key "Failed to run install_sops_key"
            fi
          '';
        };
      };
    };
    loader = {
      systemd-boot.enable = lib.mkDefault false; # using grub and not UEFI
      timeout = lib.mkForce 10;
    };
    kernel.sysctl = {
      # io_uring has been the largest source of kernel privilege escalations of the last years, and nothing here needs
      # it. 2 makes io_uring_setup fail with EPERM for every process, root included, so no ring exists at all; libuv
      # (Node) and PostgreSQL take the classic calls when it is refused. Containers share the host's kernel, so this
      # holds for them too, and the kata guests' qemu is kept off it in services/docker.nix.
      "kernel.io_uring_disabled" = 2;
      # Only the installer ISO kexecs, and it is a system of its own, without this module. The NAS's vendor kernel has
      # no kexec and no such key, and systemd-sysctl skips it there with one journal line per boot.
      "kernel.kexec_load_disabled" = 1;
      # Otherwise any process makes the kernel load a line discipline module by asking for it on a tty.
      "dev.tty.ldisc_autoload" = 0;
      # IPv4 already refuses redirects. IPv6 is off by default (ipv6.nix); this holds for a machine that turns it on.
      "net.ipv6.conf.all.accept_redirects" = 0;
      "net.ipv6.conf.default.accept_redirects" = 0;
    };
  };

  networking = {
    usePredictableInterfaceNames = false; # use eth0 instead of topology based name (like enp3s0), as I only have one network interface
    firewall.enable = true;
    firewall.allowPing = true;
    # The firewall is loaded as one nftables ruleset, all or nothing, instead of a script of iptables calls that can stop
    # half way. Rules of a module's own go in a table of its own (`networking.nftables.tables`); `extraCommands` is
    # refused by the nftables firewall.
    nftables.enable = true;
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
    group = "users";
    extraGroups = [
      "wheel"
    ];
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCv/c4C2RbcY9phczEe980HpYJJPAtLJ14cBZPk6y3yhEVIISCaUGAfIcqFRcpA59xeyNnpbyvuuYNSrBSMiFFeYdLxw++9C7LAXKCODetAZsae+qkWkdO6aw3yVF9I4vmGaN7xfroQlodfX2u0tQ1MFxhmjxnBvV14kPsxlAlWFGKE9Hx9+HMRaNi0tw+N5QGfx33wSJ5wV+Q0xunM54226WeEtXO7InbsLySHCFaV0A8GW41bjrt5Q/DNmYAOgiezR1vVz81RxSzsGc0v5hVmwdadNPBvXhBoKvYTpooXILdHvKyNNIhUMEOS6aA5HooTwcExqosMp/xyFBVqpWjnKXzP7tzvTLu7W2GyHfBcoYgk5n7/PYvgnPvpx/G0rVDMjDYz2xchi6S8Qf4isj5brnLuXSUUcB2P3pG94epajIml9HZri3P+UaueAYb6F1CJttZdZu07sGkGww1GxRBv0IlHe61/yo7ZiWjOyFfTMn5BdyNjCy3bKuGAmNhCy3aBzOoDKrLfEDkWHMRZ4ypDsCqPcLBarhgQD0qArAd3lMcWvaiBASDkNonATQ6Bvv0udm8XCpc0yeUQ4VLi1QaUHTKCE4LfL8tBJZyGdWJevnP0v+ojf+NpW7EzqypzQerP3jTzHFOfTp2zKJ+R/oJ7ZQniwt6yUvXhQ9POW+aQcQ== openpgp:0x2E6F4761"
    ];
  };

  environment.systemPackages = import ./packages.nix { inherit pkgs; };

  environment = {
    etc = {
      "issue.d/extra.issue".text = ''
        NixOS \v
        \e{green}Machine:\e{reset} \n
        \e{green}IP:\e{reset} \4
        \e{green}Today is:\e{reset} \d \t
      '';
      "profile.d/xdg_dirs_extra.sh".source = ./scripts/xdg_dirs_extra.sh;
      "isdev" = {
        text = "true";
        enable = config.setup.isDev;
      };
      "istest" = {
        text = "true";
        enable = config.setup.isTest;
      };
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

  security.pam.services.sshd.text =
    let
      pam_exec_ssh_session = pkgs.writeShellScript "pam_exec_ssh_session" ''
        logger -t pam-exec-ssh-session "START: PAM_USER='$PAM_USER'"
        USER_UID="$(id -u "$PAM_USER" 2>/dev/null)"
        USER_GID="$(id -g "$PAM_USER" 2>/dev/null)"
        logger -t pam-exec-ssh-session "PROGRESS: USER_UID='$USER_UID' USER_GID='$USER_GID'"
        if [ -z "$USER_UID" ]; then
          logger -t pam-exec-ssh-session "FAIL: USER_UID is not set"
          exit 0
        fi
        if [ -z "$USER_GID" ]; then
          logger -t pam-exec-ssh-session "FAIL: USER_GID is not set"
          exit 0
        fi
        RUNDIR="/run/user/$USER_UID"
        GNUPG_DIR="$RUNDIR/gnupg"
        logger -t pam-exec-ssh-session "FINALIZING: Creating $GNUPG_DIR for UID=$USER_UID GID=$USER_GID"
        mkdir -p -m 0700 "$GNUPG_DIR" && \
          chown "$USER_UID:$USER_GID" "$GNUPG_DIR" && \
          logger -t pam-exec-ssh-session "SUCCESS: $GNUPG_DIR created" || \
          logger -t pam-exec-ssh-session "FAIL: could not create $GNUPG_DIR"
      '';
    in
    lib.mkDefault (
      lib.mkAfter "session optional ${pkgs.pam}/lib/security/pam_exec.so ${pam_exec_ssh_session}"
    );

  programs = {
    neovim = {
      enable = true;
      defaultEditor = true;
    };
    git.enable = true;

    bash = {
      interactiveShellInit = ''
        if [[ "$TERM" == "xterm-ghostty" ]]; then
          builtin source ${pkgs.ghostty.shell_integration}/bash/ghostty.bash
        fi
      '';
    };
  };

  services = {
    openssh = {
      enable = true;
      # Only the keys the configuration declares, in /etc/ssh/authorized_keys.d. With the nixpkgs default sshd also
      # reads ~/.ssh/authorized_keys, so anything that runs as an account can add a key of its own there and keep a way
      # in that no configuration shows. A service that does keep its users' keys in its home (a git forge) gets a
      # `Match User` block of its own.
      authorizedKeysInHomedir = false;
      settings = {
        StreamLocalBindUnlink = "yes";

        # Key-only. Every account that can reach these machines has a key, so a password prompt on a public-facing
        # sshd is a guessing target and nothing else - and until the per-machine split lands, one guessed password
        # is all three servers rather than one.
        #
        # BOTH of these, and the second is the one that gets forgotten: with PasswordAuthentication off but
        # keyboard-interactive left on, PAM still offers a password over the `keyboard-interactive` method and the
        # door is exactly as open as before. `sshd -T` is the only honest way to check which is why the test reads
        # it rather than the Nix option.
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
      };
    };
    logind.settings.Login.KillUserProcesses = true;
    # A single-label name that misses DNS would otherwise be asked of the whole LAN, over LLMNR and mDNS, and any host
    # there may answer it. Nothing here resolves `.local` names; the NAS announces itself through avahi, which this
    # does not touch.
    resolved.settings.Resolve = {
      LLMNR = false;
      MulticastDNS = false;
    };
  };

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "26.05"; # Did you read the comment?

}
