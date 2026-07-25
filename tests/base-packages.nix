{ testNodes, ... }:

# Covers what modules/serverbase/packages.nix and the `programs` block of modules/serverbase/default.nix put on a server.
# The package assertions are generated from that same list, so adding a package to packages.nix is automatically covered
# here and this test never needs editing for it. Only the whole-system closure is left out: the rest of it is NixOS
# defaults, whose meta.mainProgram does not reliably name a real binary (bcache-tools, shadow, glibc...), and which are
# not ours to test.
{
  name = "base-packages";

  nodes.machine = {
    imports = [
      testNodes.base
      (
        { pkgs, lib, ... }:
        {
          setup = {
            hostName = "nixos";
            username = "giggio";
          };
          # `ghostty.terminfo` is the terminfo-only output of ghostty: it inherits ghostty's meta, so it claims
          # mainProgram "ghostty" while shipping no executable at all. It is installed for the terminfo database, which
          # the test checks separately below.
          environment.etc."test/expected-programs".text =
            let
              packages = import ../modules/serverbase/packages.nix { inherit pkgs; };
              withoutExecutable = [ pkgs.ghostty.terminfo ];
              executables = lib.lists.unique (
                builtins.filter (program: program != null) (
                  map (package: package.meta.mainProgram or null) (
                    builtins.filter (package: !(builtins.elem package withoutExecutable)) packages
                  )
                )
              );
            in
            lib.strings.concatStringsSep "\n" executables;
        }
      )
    ];
  };

  testScript = /* python */ ''
    machine.wait_for_unit("multi-user.target")

    expected = machine.succeed("cat /etc/test/expected-programs").split()
    assert len(expected) > 20, f"the generated program list looks truncated: {expected}"

    with subtest("every package declared in packages.nix puts its program on PATH"):
        missing = [
            program for program in expected
            if machine.execute(f"su -l giggio -c 'command -v {program}'")[0] != 0
        ]
        assert not missing, f"declared packages whose program is not on PATH: {missing}"

    with subtest("the terminfo-only packages populate the terminfo database"):
        for terminal in ["xterm-ghostty", "xterm-kitty"]:
            machine.succeed(f"su -l giggio -c 'infocmp {terminal} > /dev/null'")

    with subtest("neovim is installed and is the default editor"):
        machine.succeed("nvim --headless '+q'")
        editor = machine.succeed("su -l giggio -c 'echo $EDITOR'").strip()
        assert editor.endswith("nvim"), f"EDITOR is '{editor}', expected it to point at nvim"

    with subtest("git is enabled system wide"):
        machine.succeed("su -l giggio -c 'git --version'")

    with subtest("the system bashrc wires up the ghostty shell integration"):
        # Only the wiring is checked, not that the integration actually defines its functions: ghostty's script
        # deliberately bails out when it is not really running under ghostty, so asserting on its internals would be
        # testing ghostty rather than this configuration.
        bashrc = machine.succeed("cat /etc/bashrc")
        assert "xterm-ghostty" in bashrc and "/bash/ghostty.bash" in bashrc, \
            "the ghostty shell integration is not sourced from /etc/bashrc"

    (_, failed) = machine.systemctl("--failed --quiet")
    machine.log(f"systemctl --failed output: {failed}")
    assert "" == failed, "Expected no failed units and got: " + failed
  '';
}
