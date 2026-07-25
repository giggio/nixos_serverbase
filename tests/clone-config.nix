{ testNodes, ... }:

# Covers modules/serverbase/clone-config.nix and modules/serverbase/clone-script.nix: the two units that seed ~/.vim and
# ~/.config/nixos on a fresh server. Everything the script does - clone, symlink, switch the origin to the private URL,
# hand the result to the user - works over a `file://` URL, so the whole flow runs without network by pointing the units
# at bare repositories built in the store.
#
# The option surface is stressed across three nodes, because most of these settings are chosen once per machine and only
# a full evaluation shows what they produce:
#   private  - custom URLs, private origin, a symlink at a non-default location
#   public   - usePrivateRepo off, no symlink, custom clone directories, one of the two units disabled
#   derived  - no custom URLs at all, so the codeberg URLs derived from `repo` are what gets used; the clone directory
#              already exists, which both keeps the unreachable clone from running and exercises ConditionPathExists
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
          mkBareRepo =
            name: contents:
            pkgs.runCommand "${name}-test-repo" { nativeBuildInputs = [ pkgs.git ]; } ''
              export HOME="$TMPDIR"
              export GIT_CONFIG_GLOBAL="$TMPDIR/gitconfig"
              export GIT_AUTHOR_DATE="2000-01-01T00:00:00Z"
              export GIT_COMMITTER_DATE="$GIT_AUTHOR_DATE"
              git config --global user.name "test"
              git config --global user.email "test@example.invalid"
              git config --global init.defaultBranch main
              mkdir work && cd work
              ${contents}
              git init -q
              git add -A
              git commit -qm "test repo"
              cd ..
              git clone -q --bare work "$out"
            '';
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
          environment.etc."test/vimfiles-repo".source = mkBareRepo "vimfiles" ''
            echo 'let g:test = 1' > init.vim
          '';
          environment.etc."test/nixos-repo".source = mkBareRepo "nixos-config" ''
            echo '{ }' > flake.nix
          '';
        };
    in
    {
      private = {
        imports = [
          common
          {
            setup = {
              vimFiles = {
                enable = true;
                customRepoUrl = "file:///etc/test/vimfiles-repo";
                customPrivateRepoUrl = "git@example.invalid:giggio/vimfiles.git";
                usePrivateRepo = true;
                # deliberately not the default location, so that a hardcoded ~/.config/nvim would fail the test
                symlinkDir = "${home}/.config/customvim";
              };
              nixosConfig = {
                enable = true;
                customRepoUrl = "file:///etc/test/nixos-repo";
                customPrivateRepoUrl = "git@example.invalid:giggio/nixos.git";
                usePrivateRepo = true;
              };
            };
          }
        ];
      };

      public = {
        imports = [
          common
          {
            setup = {
              vimFiles = {
                enable = true;
                customRepoUrl = "file:///etc/test/vimfiles-repo";
                usePrivateRepo = false;
                symlinkDir = null;
                cloneDir = "${home}/custom-vimfiles";
              };
              # left disabled: the unit must not exist at all
              nixosConfig.enable = false;
            };
          }
        ];
      };

      derived = {
        imports = [
          common
          {
            setup = {
              vimFiles = {
                enable = true;
                repo = "someone/theirvimfiles";
                cloneDir = "/var/lib/already-cloned";
              };
              nixosConfig = {
                enable = true;
                repo = "someone/theirnixos";
                cloneDir = "/var/lib/already-cloned";
              };
            };
            # makes ConditionPathExists false before either unit ever runs, which is what keeps these unreachable
            # codeberg URLs from being fetched
            systemd.tmpfiles.rules = [ "d /var/lib/already-cloned 0755 root root -" ];
          }
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

    for machine in [private, public, derived]:
        machine.wait_for_unit("multi-user.target")

    with subtest("a private repository is cloned, symlinked where configured, and reassigned to its ssh origin"):
        wait_for_clone(private, "clone-vimfiles.service")
        wait_for_clone(private, "clone-nixos-config.service")

        private.succeed("test -f ${home}/.vim/init.vim")
        private.succeed("test -f ${home}/.config/nixos/flake.nix")
        # /etc/nixos/flake.nix is a symlink into the clone, so it only resolves once the clone has happened
        private.succeed("test -f /etc/nixos/flake.nix")

        owner = private.succeed("stat -c '%U' ${home}/.vim/init.vim").strip()
        assert owner == "${user}", f"the clone belongs to '{owner}', expected '${user}'"

        target = private.succeed("readlink ${home}/.config/customvim").strip()
        assert target == "${home}/.vim", \
            f"the symlink points at '{target}', expected it at the configured symlinkDir"
        private.fail("test -e ${home}/.config/nvim")

        for directory, expected in [("${home}/.vim", "git@example.invalid:giggio/vimfiles.git"),
                                    ("${home}/.config/nixos", "git@example.invalid:giggio/nixos.git")]:
            origin = origin_of(private, directory)
            assert origin == expected, f"{directory} origin is '{origin}', expected '{expected}'"

    with subtest("a second run is skipped because the clone directory already exists"):
        for unit in ["clone-vimfiles.service", "clone-nixos-config.service"]:
            private.succeed(f"systemctl start {unit}")
            condition = private.succeed(f"systemctl show -p ConditionResult --value {unit}").strip()
            assert condition == "no", \
                f"{unit} ran again instead of being skipped by ConditionPathExists (ConditionResult={condition})"

    with subtest("in a test the units fail fast instead of retrying for ten minutes"):
        for unit in ["clone-vimfiles.service", "clone-nixos-config.service"]:
            restart = private.succeed(f"systemctl show -p Restart --value {unit}").strip()
            assert restart == "no", f"{unit} has Restart={restart}, expected 'no' in a test build"

    with subtest("without a private repo the origin is left alone, and without a symlinkDir nothing is linked"):
        wait_for_clone(public, "clone-vimfiles.service")

        public.succeed("test -f ${home}/custom-vimfiles/init.vim")
        origin = origin_of(public, "${home}/custom-vimfiles")
        assert origin == "file:///etc/test/vimfiles-repo", \
            f"the origin was rewritten to '{origin}' even though usePrivateRepo is off"
        public.fail("test -e ${home}/.config/nvim")
        public.fail("test -e ${home}/.vim")

    with subtest("a disabled clone is masked, so it can never run"):
        # NixOS renders a disabled service as a symlink to /dev/null rather than omitting the file
        for unit, expected in [("clone-nixos-config.service", "masked"), ("clone-vimfiles.service", "loaded")]:
            state = public.succeed(f"systemctl show -p LoadState --value {unit}").strip()
            assert state == expected, f"{unit} is '{state}', expected '{expected}'"
        public.fail("test -e ${home}/.config/nixos")

    with subtest("without custom URLs the codeberg URLs are derived from the repo name"):
        for unit, repo in [("clone-vimfiles.service", "someone/theirvimfiles"),
                           ("clone-nixos-config.service", "someone/theirnixos")]:
            # the URLs end up in the unit's generated start script, which systemctl only references by path
            exec_start = derived.succeed(f"systemctl show -p ExecStart --value {unit}")
            script = derived.succeed("cat " + exec_start.split("path=")[1].split(";")[0].strip())
            assert f"https://codeberg.org/{repo}.git" in script, \
                f"{unit} does not clone from the codeberg URL derived from '{repo}'"
            assert f"git@codeberg.org:{repo}.git" in script, \
                f"{unit} does not use the ssh origin derived from '{repo}'"
            # the clone directory was created before boot, so the unit must never have run
            condition = derived.succeed(f"systemctl show -p ConditionResult --value {unit}").strip()
            assert condition == "no", \
                f"{unit} ran against an unreachable URL instead of being skipped (ConditionResult={condition})"

    with subtest("the clone script reports what it would do without touching anything when asked to dry run"):
        output = private.succeed(
            "clone --dry-run file:///etc/test/vimfiles-repo /tmp/dry --symlink /tmp/dry-link"
            " --private-git-origin git@example.invalid:x/y.git --chown ${user}"
        )
        for expected in ["git clone", "/tmp/dry", "ln -s", "/tmp/dry-link", "git remote set-url"]:
            assert expected in output, f"the dry run did not mention '{expected}': {output}"
        private.fail("test -e /tmp/dry")
        private.fail("test -e /tmp/dry-link")

    with subtest("the clone script rejects incomplete or unknown arguments"):
        private.fail("clone 2>/dev/null")
        private.fail("clone file:///etc/test/vimfiles-repo 2>/dev/null")
        private.fail("clone --symlink 2>/dev/null")
        private.fail("clone --nonsense file:///etc/test/vimfiles-repo /tmp/nope 2>/dev/null")
        private.fail("clone file:///etc/test/vimfiles-repo /tmp/a /tmp/b 2>/dev/null")

    with subtest("the clone script leaves ownership alone when no chown is asked for"):
        private.succeed("clone file:///etc/test/vimfiles-repo /tmp/asroot")
        owner = private.succeed("stat -c '%U' /tmp/asroot/init.vim").strip()
        assert owner == "root", f"the clone belongs to '{owner}', expected it left as 'root'"

    for machine in [private, public, derived]:
        (_, failed) = machine.systemctl("--failed --quiet")
        machine.log(f"systemctl --failed output: {failed}")
        assert "" == failed, "Expected no failed units and got: " + failed
  '';
}
