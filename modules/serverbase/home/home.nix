# The servers' home-manager configuration is home-manager-config, the same repository the PC uses, checked out as the
# ../home-manager submodule and switched to its server profile with `setup.homeManager.isServer`.
#
# Its package set and its home-manager module come from the revisions that repository pins itself (./hm-inputs.nix):
# nixos-unstable and home-manager master. The system stays on this flake's nixos-26.05 - only what the user profile
# installs is unstable, and nothing that runs as a service depends on it.
{
  config,
  pkgs,
  lib,
  ...
}:

let
  hmInputs = import ./hm-inputs.nix ../home-manager/flake.lock;
  hmOverlay = import ../home-manager/pkgs/hm-pkgs.nix hmInputs;
  # Leaf tools the system already carries, taken from it instead of being installed a second time from unstable - on a
  # 32 GB SD card the copies are what hurts. Leaves only: swapping anything other packages are built against (python3,
  # systemd, gettext) would change the hash of every dependent and turn cache hits into local builds.
  #   mylua      the system's is a superset (it adds tiktoken_core), and luarocks drags cmake in with it
  #   zellij     the one on PATH is the system's anyway, and .bashrc should call the same binary
  #   todos      a script around python3 and ripgrep, both of which the system has
  #   nix-direnv otherwise brings a whole second nix, with boost and icu
  systemCopies = final: prev: {
    inherit (pkgs) mylua zellij;
    inherit (hmOverlay pkgs pkgs) todos;
    nix-direnv = prev.nix-direnv.override { nix = config.nix.package; };
  };
  hmPkgs = import hmInputs.nixpkgs.outPath {
    inherit (pkgs.stdenv.hostPlatform) system;
    # Not the config the PC gives its whole system: `rocmSupport` there would change the hash of every package and turn
    # each cache.nixos.org hit into a local build.
    overlays = [
      hmOverlay
      systemCopies
    ];
  };
in
{
  imports = [ hmInputs.home-manager.nixosModules.home-manager ];

  home-manager = {
    # true even though the package set is not the system's: it keeps home.nix away from `nixpkgs.*`, and the set is
    # swapped for hmPkgs below.
    useGlobalPkgs = true;
    useUserPackages = true;
    # A file already in the way of a link is moved aside instead of failing the activation. Machines that predate the
    # submodule have ~/.vim as a clone of its own and ~/.config/nvim as a link to it, both of which are links into the
    # submodule now.
    backupFileExtension = "hm-backup";
    users.${config.setup.username} = ../home-manager/home.nix;
    extraSpecialArgs = {
      inputs = hmInputs;
      pkgs-stable = pkgs;
      # home-manager builds its `lib` from the system's, 26.05's, and hands it to modules that also reach into the
      # unstable pkgs.path - lib/services/lib.nix from unstable calls a lib.importService that 26.05 does not have. The
      # modules get the lib of the nixpkgs they were written against instead; extraSpecialArgs is merged last, so this
      # replaces home-manager's own.
      lib = import "${hmInputs.home-manager}/modules/lib/stdlib-extended.nix" hmInputs.nixpkgs.lib;
    };
    sharedModules = [
      ../options.nix
      ../home-manager/options.nix
      {
        # home-manager passes its pkgs in with mkDefault (modules/modules.nix), so this replaces it for every module
        _module.args.pkgs = lib.mkForce hmPkgs;
        # The same reason as systemCopies above, for what home-manager takes from pkgs on its own: the running systemd's
        # systemctl rather than a second, unstable systemd, and no MIME database for a machine that opens no file by type.
        systemd.user.systemctlPath = "${config.systemd.package}/bin/systemctl";
        xdg.mime.enable = false;
        programs.gpg.package = pkgs.gnupg;
        # home-manager's user tmpfiles run the unstable systemd-tmpfiles, and that alone keeps the whole second systemd
        # in the closure. The system's per-user tmpfiles below do the same job. Its one rule from home-manager-config,
        # ~/.ssh/config.d, holds decrypted secrets that a server does not have.
        systemd.user.tmpfiles.rules = lib.mkForce [ ];
        # backupFileExtension moves files and directories aside, but refuses a symlink it does not own - and the old
        # ~/.config/nvim is one, to the ~/.vim clone that does get moved. Losing the link loses nothing.
        xdg.configFile."nvim".force = true;
        setup = {
          username = config.setup.username;
          homeManager = {
            platform = "nixos";
            isServer = true;
            isVM = config.setup.isVM;
            hostName = config.networking.hostName;
            # where clone-config.nix clones the configuration, and so where the out-of-store links point
            configPath = "${config.setup.nixosConfig.cloneDir}/nixos_serverbase/modules/serverbase/home-manager";
          };
        };
      }
    ];
  };

  # .gitconfig keeps credentials in a store file under this directory. Created with a mode no other account can read,
  # instead of letting the first `git` that stores a credential create it with the umask's.
  systemd.user.tmpfiles.users.${config.setup.username}.rules = [
    "d %h/.cache/git/credential 0700 - - -"
  ];

  # The zellij configuration loads its plugins from /run/current-system/sw/share/zellij, so they are a system package
  environment.systemPackages = [ hmPkgs.zellij_plugins ];
}
