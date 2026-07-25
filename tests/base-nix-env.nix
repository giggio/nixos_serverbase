{ testNodes, ... }:

# Covers the parts of modules/serverbase/default.nix that shape the environment a login lands in: the nix daemon's
# settings, the login banner, the XDG variables exported from /etc/profile.d, the timezone and the locale.
#
# Every nix setting is read back with `nix config show`, which reports the value the daemon actually resolved rather than
# the text of the file that was written - a setting that nix does not understand is silently ignored, and grepping
# nix.conf would not notice. What the sops-backed settings *point at* is checked in the secrets-sops test, since without
# a key there is nothing at the other end of the path.
{
  name = "base-nix-env";

  nodes.machine = {
    imports = [
      testNodes.base
      {
        setup = {
          hostName = "nixos";
          username = "giggio";
        };
      }
    ];
  };

  testScript = # python
    ''
      machine.wait_for_unit("multi-user.target")

      def nix_setting(name):
          return machine.succeed(f"nix config show {name}").strip()

      def login_shell_variable(name):
          # a login shell, because that is the only kind that reads /etc/profile and so /etc/profile.d
          return machine.succeed(f"su -l giggio -c 'printf %s \"${"$"}{name}\"'").strip()

      with subtest("flakes and the new cli are enabled"):
          features = nix_setting("experimental-features").split()
          for feature in ["nix-command", "flakes"]:
              assert feature in features, f"'{feature}' is not enabled, only {features}"
          # not just configured but usable: both subcommands only exist when the features above are on
          machine.succeed("nix eval --expr '1 + 1' --impure")
          machine.succeed("nix flake --help")

      with subtest("the personal binary cache is trusted"):
          keys = nix_setting("trusted-public-keys")
          assert "giggio:gA25EMS+ouiC1xzWOKP68b7ikEfjmXohUT1PZ6aNP5c=" in keys, \
              f"the personal cache's key is not trusted, only: {keys}"

      with subtest("the daemon reads its credentials from the paths sops renders"):
          netrc = nix_setting("netrc-file")
          assert netrc.startswith("/run/secrets/"), \
              f"netrc-file is '{netrc}', expected a path sops renders under /run/secrets"
          # `!include` (as opposed to `include`) is what keeps a machine bootable when the secret is not there yet
          config_file = machine.succeed("cat /etc/nix/nix.conf")
          assert "!include /run/secrets/" in config_file, \
              f"nix.conf does not optionally include the secret options file: {config_file}"

      with subtest("the login banner announces the machine, its address and the time"):
          banner = machine.succeed("cat /etc/issue.d/extra.issue")
          for escape in [r"\n", r"\4", r"\d \t"]:
              assert escape in banner, f"the banner does not print {escape}: {banner}"

      with subtest("a login shell gets the XDG directories spelled out"):
          for variable, expected in [
              ("XDG_CONFIG_HOME", "/home/giggio/.config"),
              ("XDG_DATA_HOME", "/home/giggio/.local/share"),
              ("XDG_STATE_HOME", "/home/giggio/.local/state"),
              ("XDG_CACHE_HOME", "/home/giggio/.cache"),
          ]:
              value = login_shell_variable(variable)
              assert value == expected, f"{variable} is '{value}', expected '{expected}'"

          # XDG_CONFIG_DIRS and XDG_DATA_DIRS are deliberately not asserted against the script's values: NixOS exports
          # both of them itself, before /etc/profile.d is read, so the script's `if ! [ -v ... ]` never fires for them
          # and its /usr/share fallbacks are dead here. What is asserted is that they end up pointing somewhere.
          for variable in ["XDG_CONFIG_DIRS", "XDG_DATA_DIRS"]:
              assert login_shell_variable(variable) != "", f"{variable} is empty"

      with subtest("the machine keeps São Paulo time"):
          zone = machine.succeed("readlink -f /etc/localtime").strip()
          assert zone.endswith("/America/Sao_Paulo"), f"/etc/localtime points at {zone}"
          offset = machine.succeed("date +%z").strip()
          assert offset == "-0300", f"the clock is at UTC{offset}, expected UTC-0300"

      with subtest("the locale is american english everywhere"):
          for variable in ["LANG", "LC_TIME", "LC_MEASUREMENT", "LC_MONETARY", "LC_NUMERIC", "LC_PAPER"]:
              value = login_shell_variable(variable)
              assert value == "en_US.UTF-8", f"{variable} is '{value}', expected 'en_US.UTF-8'"

      with subtest("the system flake is looked up in the cloned configuration"):
          # -m, not -f: the target is inside the clone, which a test never has, and -f gives up on a dangling link.
          # /etc entries are themselves symlinks through /etc/static, so the link has to be followed all the way.
          target = machine.succeed("readlink -m /etc/nixos/flake.nix").strip()
          # a symlink into the user's clone, not a copy in the store: `nixos-rebuild` has to see the working tree
          assert target == "/home/giggio/.config/nixos/flake.nix", \
              f"/etc/nixos/flake.nix points at '{target}'"

      (_, failed) = machine.systemctl("--failed --quiet")
      machine.log(f"systemctl --failed output: {failed}")
      assert "" == failed, "Expected no failed units and got: " + failed
    '';
}
