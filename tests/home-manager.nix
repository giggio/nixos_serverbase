{ testNodes, ... }:

# Covers modules/serverbase/home: home-manager-config, the submodule at modules/serverbase/home-manager, in its server
# profile. Almost nothing here is visible to the system: it is a pile of dotfiles
# and shell wiring that only exists once the user's shell has read them, so the check opens shells - a login shell for
# what .profile and hm-session-vars.sh export, an interactive one for what .bashrc sets up - instead of looking at the
# files home-manager wrote.
#
# The user manager is started explicitly with `loginctl enable-linger`, because a `su` is not a session: without it there
# is no /run/user/1000 and none of the user's systemd units ever run.
let
  user = "giggio";
  home = "/home/${user}";
  # where the out-of-store symlinks point; the clone does not exist in a test, and the link is expected to dangle
  repoConfig = "${home}/.config/nixos/nixos_serverbase/modules/serverbase/home-manager";
in
{
  name = "home-manager";

  nodes.machine = {
    imports = [
      testNodes.base
      {
        setup = {
          hostName = "nixos";
          username = user;
        };
        # What a server that predates the submodule has where home-manager now wants its links: vimfiles cloned into
        # ~/.vim by the unit that used to do it, and ~/.config/nvim linked to that clone. tmpfiles runs in sysinit,
        # before the activation does.
        systemd.tmpfiles.rules = [
          "d ${home}/.vim 0755 ${user} users -"
          "f ${home}/.vim/init.vim 0644 ${user} users - \" the old clone"
          "d ${home}/.config 0755 ${user} users -"
          "L ${home}/.config/nvim - - - - ${home}/.vim"
        ];
      }
    ];
  };

  testScript = # python
    ''
      import shlex

      machine.wait_for_unit("multi-user.target")

      def login_shell(command):
          # -l, so that /etc/profile, ~/.profile and hm-session-vars.sh are all read
          return machine.succeed("su -l ${user} -c " + shlex.quote(command)).strip()

      def interactive_shell(command):
          # a login shell never reads .bashrc, which is where home-manager puts the aliases and the shell integrations.
          # TERM has to be a real terminal: the driver runs with TERM=dumb, and the prompt is only set up when it is not.
          # Loading .bashrc writes to stdout on its own (`tabs -4` emits escape sequences), so the command's own output
          # is fenced off with a marker rather than being read from the top of the stream.
          marker = "-----"
          inner = "TERM=xterm-256color bash -ic " + shlex.quote(f"printf %s {marker}; " + command)
          output = machine.succeed("su -l ${user} -c " + shlex.quote(inner))
          return output.split(marker, 1)[1].strip()

      with subtest("home-manager activated the user's home"):
          machine.wait_for_unit("home-manager-${user}.service")
          state = machine.succeed("systemctl is-active home-manager-${user}.service").strip()
          assert state == "active", f"the home-manager activation unit is '{state}'"

      with subtest("the dotfiles are managed and point into the store"):
          for path in [
              ".hushlogin",
              ".tmux.conf",
              ".inputrc",
              ".vimrc",
              ".config/starship.toml",
              ".config/blesh/init.sh",
          ]:
              target = machine.succeed(f"readlink -m ${home}/{path}").strip()
              assert target.startswith("/nix/store/"), \
                  f"{path} is not a home-manager managed link into the store, it points at '{target}'"

      with subtest("the configuration that is edited by hand is linked out of the store"):
          # These are deliberately out-of-store symlinks: edited in the clone and picked up without a rebuild. They
          # dangle until the machine has cloned its configuration, which a test never does. -m follows the whole
          # chain: home-manager links the entry to its own generation in the store, and only that link points back out
          # at the working copy. vimfiles is the submodule's own submodule, which is why nothing clones it separately.
          for path, expected in [
              (".config/zellij", "config/zellij"),
              (".config/git", "config/git"),
              (".gitconfig", "home/.gitconfig"),
              (".vim", "config/vimfiles"),
              (".config/nvim", "config/vimfiles"),
          ]:
              target = machine.succeed(f"readlink -m ${home}/{path}").strip()
              assert target == f"${repoConfig}/{expected}", \
                  f"{path} points at '{target}', which is not the working copy's {expected}"

      with subtest("the old vimfiles clone was moved aside, not lost"):
          # planted by tmpfiles before the activation ran; its ~/.config/nvim link is simply replaced
          machine.succeed("test -f ${home}/.vim.hm-backup/init.vim")

      with subtest("the server profile leaves out what only the PC has"):
          # the coding agents' configuration, and the desktop's compose key table
          for path in [".claude/skills", ".agents/skills", ".config/opencode/agents", ".XCompose"]:
              machine.fail(f"test -L ${home}/{path}")
          # docker is rootful here, and the PC's DOCKER_HOST points at a rootless socket this machine does not have
          assert login_shell('printf %s "''${DOCKER_HOST:-}"') == "", "DOCKER_HOST is set, docker cannot reach the daemon"
          # the .NET SDK, most of a gigabyte, comes in through this variable
          assert interactive_shell('printf %s "''${DOTNET_ROOT:-}"') == "", "DOTNET_ROOT is set, so the .NET SDK came along"

      with subtest("a login shell carries the session variables"):
          for variable, expected in [
              ("IS_SERVER", "1"),
              ("TMP", "/tmp"),
              ("TEMP", "/tmp"),
          ]:
              value = login_shell(f'printf %s "${"$"}{variable}"')
              assert value == expected, f"{variable} is '{value}' in a login shell, expected '{expected}'"

          path = login_shell('printf %s "$PATH"').split(":")
          assert "${home}/.local/bin" in path, f"the user's own bin directory is not on PATH: {path}"

      with subtest("an interactive shell gets the aliases"):
          for alias, expected in [("ll", "eza"), ("vim", "nvim"), ("st", "git status")]:
              definition = interactive_shell(f"type {alias}")
              assert expected in definition, f"'{alias}' does not resolve to {expected}: {definition}"

          # The aliases have to run, not only exist. The system's eza is from the stable channel, and 0.23.4 refused
          # the `--hyperlink=always` they pass, so the user's must come first in PATH.
          eza = interactive_shell("type -P eza")
          assert eza.startswith("/etc/profiles/per-user/${user}/"), f"eza resolves to {eza}, not the home profile's"
          for command in ["ll /", "l /", "tree -L 1 /"]:
              interactive_shell(command)

      with subtest("an interactive shell gets the shell integrations"):
          # starship_precmd rather than PROMPT_COMMAND: with ble.sh loaded, which .bashrc does unless told not to,
          # starship registers it with ble.sh's own hook instead, and `bash -ic` never draws a prompt to fill PS1
          for function in ["starship_precmd", "_direnv_hook", "z"]:
              kind = interactive_shell(f"type -t {function} || true")
              assert kind == "function", f"'{function}' is a '{kind}', expected a shell function"

          # the agent the PC forwards (sudo.nix) must survive .bashrc: neither a gpg-agent with ssh support nor the
          # PC's ssh-socket.bash may take SSH_AUTH_SOCK over
          uid = machine.succeed("id -u ${user}").strip()
          sock = interactive_shell('printf %s "$SSH_AUTH_SOCK"')
          assert sock == f"/run/user/{uid}/ssh-remote-agent.sock", \
              f"SSH_AUTH_SOCK is '{sock}' in an interactive shell, not the forwarded agent"

      with subtest("the lua interpreter finds both the packaged and the user installed modules"):
          lua_path = interactive_shell('printf %s "$LUA_PATH"')
          assert "/share/lua/5.1/?.lua" in lua_path, f"LUA_PATH does not include mylua's modules: {lua_path}"
          assert "${home}/.luarocks/share/lua/5.1/?.lua" in lua_path, \
              f"LUA_PATH does not include the user's own rocks: {lua_path}"

      with subtest("the gpg key is imported and ultimately trusted"):
          keys = login_shell("gpg --list-keys --with-colons")
          assert "1237AB122E6F4761" in keys, f"the personal gpg key was not imported: {keys}"
          for line in keys.splitlines():
              if line.startswith("pub:"):
                  fields = line.split(":")
                  assert fields[1] == "u" and fields[8] == "u", \
                      f"the key is not ultimately trusted and valid: {line}"

      with subtest("a real session gets its runtime directory and the user's own units run"):
          machine.succeed("loginctl enable-linger ${user}")
          uid = machine.succeed("id -u ${user}").strip()
          machine.wait_for_unit(f"user@{uid}.service")
          machine.wait_for_file(f"/run/user/{uid}")

          # rstrip, because a shell that gets here through .profile's fallback rather than through pam_systemd ends up
          # with a trailing slash. Either way it has to name the directory logind created.
          runtime_dir = login_shell('printf %s "$XDG_RUNTIME_DIR"').rstrip("/")
          assert runtime_dir == f"/run/user/{uid}", \
              f"XDG_RUNTIME_DIR is '{runtime_dir}' in a login shell, expected /run/user/{uid}"
          machine.succeed(f"test -d {runtime_dir}")

          # the user's tmpfiles rules only run inside the user manager, which is why the linger above is needed
          credentials = "${home}/.cache/git/credential"
          machine.wait_for_file(credentials)
          ownership = machine.succeed(f"stat -c '%a %U' {credentials}").strip()
          assert ownership == "700 ${user}", \
              f"{credentials} is '{ownership}', expected '700 ${user}' so no other account can read stored credentials"

      (_, failed) = machine.systemctl("--failed --quiet")
      machine.log(f"systemctl --failed output: {failed}")
      assert "" == failed, "Expected no failed units and got: " + failed
    '';
}
