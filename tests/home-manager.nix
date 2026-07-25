{ testNodes, ... }:

# Covers modules/serverbase/home-manager/home.nix. Almost nothing here is visible to the system: it is a pile of dotfiles
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
              ".gitconfig",
              ".hushlogin",
              ".tmux.conf",
              ".inputrc",
              ".vimrc",
              ".local/bin/nr",
              ".config/starship.toml",
              ".config/git",
              ".config/blesh/init.sh",
          ]:
              target = machine.succeed(f"readlink -m ${home}/{path}").strip()
              assert target.startswith("/nix/store/"), \
                  f"{path} is not a home-manager managed link into the store, it points at '{target}'"

      with subtest("the configuration that is edited by hand is linked out of the store"):
          # zellij's configuration is deliberately an out-of-store symlink: it is edited in the clone and picked up
          # without a rebuild. It dangles until the machine has cloned its configuration, which a test never does.
          # -m follows the whole chain: home-manager links the entry to its own generation in the store, and only that
          # link points back out at the working copy
          target = machine.succeed("readlink -m ${home}/.config/zellij").strip()
          assert target == "${repoConfig}/config/zellij", \
              f".config/zellij points at '{target}', which is not the working copy"

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

      with subtest("an interactive shell gets the shell integrations"):
          assert "starship" in interactive_shell('printf %s "$PROMPT_COMMAND"'), \
              "starship is not driving the prompt"
          for function in ["_direnv_hook", "z"]:
              kind = interactive_shell(f"type -t {function} || true")
              assert kind == "function", f"'{function}' is a '{kind}', expected a shell function"

          # atuin is installed but deliberately not hooked into bash: its integration is only wanted under the
          # terminals that also load ble.sh, which a server session is not
          assert interactive_shell("type -t _atuin_search || true") == "", \
              "atuin hooked itself into bash, but enableBashIntegration is off"

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
