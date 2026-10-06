{ testNodes, ... }:

# Covers modules/serverbase/clone-config.nix and modules/serverbase/clone-script.nix: the unit that seeds /etc/nixos
# on a fresh server. Everything the script does - clone with the submodules, switch the origin to the private URL, hand
# the result to the user - works over a `file://` URL, so the whole flow runs without network by pointing the unit at
# bare repositories built in the store.
#
# The configuration repository here nests relative submodules two levels deep, the way the real one does
# (a superproject -> nixos_serverbase -> home-manager-config -> vimfiles): the clone has to bring all of them, and
# switching to the private origin has to reach all of them too.
#
# The option surface is stressed across four nodes, because most of these settings are chosen once per machine and only
# a full evaluation shows what they produce:
#   private  - custom URLs, private origin
#   public   - usePrivateRepo off, a custom clone directory
#   derived  - no custom URLs at all, so the codeberg URLs derived from `repo` are what gets used; the clone directory
#              already exists, which both keeps the unreachable clone from running and exercises ConditionPathExists
#   disabled - the unit turned off
#
# Not covered: `nixosConfig.useCredentials`. The askpass file is only wired up for https:// URLs, so exercising it needs
# an authenticating https server rather than a repository in the store.
let
  user = "giggio";
  home = "/home/${user}";
in
{
  name = "clone-config";

  nodes =
    let
      common =
        { pkgs, ... }:
        let
          # `submodules` are gitlinks to other test repositories, by relative URL: resolved against the origin at clone
          # time, so /etc/test/<name>-repo, which is where each one is installed below
          mkBareRepo =
            name: contents: submodules:
            pkgs.runCommand "${name}-test-repo" { nativeBuildInputs = [ pkgs.git ]; } ''
              export HOME="$TMPDIR"
              export GIT_CONFIG_GLOBAL="$TMPDIR/gitconfig"
              export GIT_AUTHOR_DATE="2000-01-01T00:00:00Z"
              export GIT_COMMITTER_DATE="$GIT_AUTHOR_DATE"
              git config --global user.name "test"
              git config --global user.email "test@example.invalid"
              git config --global init.defaultBranch main
              # the submodules' repositories are store paths, which the build user does not own
              git config --global safe.directory '*'
              mkdir work && cd work
              ${contents}
              git init -q
              git add -A
              # after `git add -A`, which would stage the gitlinks' paths as deleted: nothing is checked out at them
              ${pkgs.lib.concatMapStrings (sub: ''
                git config -f .gitmodules submodule.${sub.name}.path ${sub.name}
                git config -f .gitmodules submodule.${sub.name}.url ../${sub.name}-repo
                git update-index --add --cacheinfo 160000,"$(git -C ${sub.repo} rev-parse HEAD)",${sub.name}
                git add .gitmodules
              '') submodules}
              git commit -qm "test repo"
              cd ..
              git clone -q --bare work "$out"
            '';
          vimRepo = mkBareRepo "vim" "echo 'let g:test = 1' > init.vim" [ ];
          homeRepo = mkBareRepo "home" "echo '{ }' > home.nix" [
            {
              name = "vim";
              repo = vimRepo;
            }
          ];
          nixosRepo = mkBareRepo "nixos" "echo '{ }' > flake.nix" [
            {
              name = "home";
              repo = homeRepo;
            }
          ];
        in
        {
          imports = [
            testNodes.base
            {
              setup = {
                hostName = "nixos";
                username = user;
              };
            }
          ];
          # exposed so the script's own branches can be driven directly, without going through a systemd unit
          environment.systemPackages = [ (import ../modules/serverbase/clone-script.nix { inherit pkgs; }) ];
          environment.etc = {
            "test/nixos-repo".source = nixosRepo;
            "test/home-repo".source = homeRepo;
            "test/vim-repo".source = vimRepo;
          };
          # git refuses file:// submodules unless told otherwise, since CVE-2022-39253. Only the test's repositories
          # are local; a real server clones over https or ssh.
          systemd.services.clone-nixos-config.environment = {
            GIT_CONFIG_COUNT = "1";
            GIT_CONFIG_KEY_0 = "protocol.file.allow";
            GIT_CONFIG_VALUE_0 = "always";
          };
        };
    in
    {
      private = {
        imports = [
          common
          {
            setup.nixosConfig = {
              enable = true;
              customRepoUrl = "file:///etc/test/nixos-repo";
              customPrivateRepoUrl = "git@example.invalid:giggio/nixos.git";
              usePrivateRepo = true;
            };
          }
        ];
      };

      public = {
        imports = [
          common
          {
            setup.nixosConfig = {
              enable = true;
              customRepoUrl = "file:///etc/test/nixos-repo";
              usePrivateRepo = false;
              cloneDir = "${home}/custom-nixos";
            };
          }
        ];
      };

      derived = {
        imports = [
          common
          {
            setup.nixosConfig = {
              enable = true;
              repo = "someone/theirnixos";
              cloneDir = "/var/lib/already-cloned";
            };
            # makes ConditionPathExists false before the unit ever runs, which is what keeps this unreachable codeberg
            # URL from being fetched
            systemd.tmpfiles.rules = [ "d /var/lib/already-cloned/.git 0755 root root -" ];
          }
        ];
      };

      disabled = {
        imports = [
          common
          { setup.nixosConfig.enable = false; }
        ];
      };
    };

  testScript = /* python */ ''
    def wait_for_clone(machine, unit):
        machine.wait_until_succeeds(
            f"systemctl show -p Result --value {unit} | grep -qx success", timeout=60
        )


    def origin_of(machine, directory):
        # asked as the owner: git refuses to read a repository belonging to another user
        return machine.succeed(f"su ${user} -c 'git -C {directory} remote get-url origin'").strip()


    start_all()

    for machine in [private, public, derived, disabled]:
        machine.wait_for_unit("multi-user.target")

    with subtest("a private repository is cloned with its nested submodules and reassigned to its ssh origin"):
        wait_for_clone(private, "clone-nixos-config.service")

        private.succeed("test -f /etc/nixos/flake.nix")
        private.succeed("test -f /etc/nixos/home/home.nix")
        private.succeed("test -f /etc/nixos/home/vim/init.vim")

        owner = private.succeed("stat -c '%U' /etc/nixos/home/vim/init.vim").strip()
        assert owner == "${user}", f"the nested clone belongs to '{owner}', expected '${user}'"

        # every level resolves its relative URL against the private origin, which only happens when the sync recurses
        for directory, expected in [("/etc/nixos", "git@example.invalid:giggio/nixos.git"),
                                    ("/etc/nixos/home", "git@example.invalid:giggio/home-repo"),
                                    ("/etc/nixos/home/vim", "git@example.invalid:giggio/vim-repo")]:
            origin = origin_of(private, directory)
            assert origin == expected, f"{directory} origin is '{origin}', expected '{expected}'"

    with subtest("a second run is skipped because the clone directory already exists"):
        private.succeed("systemctl start clone-nixos-config.service")
        condition = private.succeed("systemctl show -p ConditionResult --value clone-nixos-config.service").strip()
        assert condition == "no", \
            f"the clone ran again instead of being skipped by ConditionPathExists (ConditionResult={condition})"

    with subtest("in a test the unit fails fast instead of retrying for ten minutes"):
        restart = private.succeed("systemctl show -p Restart --value clone-nixos-config.service").strip()
        assert restart == "no", f"the clone has Restart={restart}, expected 'no' in a test build"

    with subtest("without a private repo the origin is left alone"):
        wait_for_clone(public, "clone-nixos-config.service")

        public.succeed("test -f ${home}/custom-nixos/home/vim/init.vim")
        origin = origin_of(public, "${home}/custom-nixos")
        assert origin == "file:///etc/test/nixos-repo", \
            f"the origin was rewritten to '{origin}' even though usePrivateRepo is off"
        public.fail("test -e /etc/nixos/flake.nix")

    with subtest("a disabled clone is masked, so it can never run"):
        # NixOS renders a disabled service as a symlink to /dev/null rather than omitting the file
        state = disabled.succeed("systemctl show -p LoadState --value clone-nixos-config.service").strip()
        assert state == "masked", f"the disabled clone is '{state}', expected 'masked'"
        disabled.fail("test -e /etc/nixos/flake.nix")

    with subtest("without custom URLs the codeberg URLs are derived from the repo name"):
        # the URLs end up in the unit's generated start script, which systemctl only references by path
        exec_start = derived.succeed("systemctl show -p ExecStart --value clone-nixos-config.service")
        script = derived.succeed("cat " + exec_start.split("path=")[1].split(";")[0].strip())
        assert "https://codeberg.org/someone/theirnixos.git" in script, \
            "the clone does not use the codeberg URL derived from 'someone/theirnixos'"
        assert "git@codeberg.org:someone/theirnixos.git" in script, \
            "the clone does not use the ssh origin derived from 'someone/theirnixos'"
        # the clone directory was created before boot, so the unit must never have run
        condition = derived.succeed("systemctl show -p ConditionResult --value clone-nixos-config.service").strip()
        assert condition == "no", \
            f"the clone ran against an unreachable URL instead of being skipped (ConditionResult={condition})"

    with subtest("the clone script reports what it would do without touching anything when asked to dry run"):
        output = private.succeed(
            "clone --dry-run file:///etc/test/vim-repo /tmp/dry --symlink /tmp/dry-link"
            " --private-git-origin git@example.invalid:x/y.git --chown ${user}"
        )
        for expected in ["git clone", "/tmp/dry", "ln -s", "/tmp/dry-link", "git remote set-url",
                         "git submodule sync --recursive"]:
            assert expected in output, f"the dry run did not mention '{expected}': {output}"
        private.fail("test -e /tmp/dry")
        private.fail("test -e /tmp/dry-link")

    with subtest("the clone script links the clone where --symlink asks"):
        # no unit passes --symlink since vimfiles stopped being cloned on its own, so the script is driven directly
        private.succeed("clone file:///etc/test/vim-repo /tmp/linked --symlink /tmp/linked-alias --chown ${user}")
        target = private.succeed("readlink /tmp/linked-alias").strip()
        assert target == "/tmp/linked", f"the symlink points at '{target}', expected the clone"
        private.succeed("test -f /tmp/linked-alias/init.vim")

    with subtest("the clone script rejects incomplete or unknown arguments"):
        private.fail("clone 2>/dev/null")
        private.fail("clone file:///etc/test/vim-repo 2>/dev/null")
        private.fail("clone --symlink 2>/dev/null")
        private.fail("clone --chown 2>/dev/null")
        private.fail("clone --nonsense file:///etc/test/vim-repo /tmp/nope 2>/dev/null")
        private.fail("clone file:///etc/test/vim-repo /tmp/a /tmp/b 2>/dev/null")

    with subtest("the clone script leaves ownership alone when no chown is asked for"):
        private.succeed("clone file:///etc/test/vim-repo /tmp/asroot")
        owner = private.succeed("stat -c '%U' /tmp/asroot/init.vim").strip()
        assert owner == "root", f"the clone belongs to '{owner}', expected it left as 'root'"

    for machine in [private, public, derived, disabled]:
        (_, failed) = machine.systemctl("--failed --quiet")
        machine.log(f"systemctl --failed output: {failed}")
        assert "" == failed, "Expected no failed units and got: " + failed
  '';
}
