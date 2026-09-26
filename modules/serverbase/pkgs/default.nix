{ pkgs }:

with pkgs;
{
  mylua = (
    lua5_1.withPackages (
      ps: with ps; [
        luarocks # A package manager for Lua modules https://luarocks.org/
        tiktoken_core # An experimental port of OpenAI's Tokenizer to lua # used for Github Copilot chat nvim plugin # https://github.com/gptlang/lua-tiktoken
        # luacheck # A static analyzer and a linter for Lua
        inspect # Human-readable representation of Lua tables https://github.com/kikito/inspect.lua
        busted # Elegant Lua unit testing # https://lunarmodules.github.io/busted/
        luasystem # Platform independent system calls for Lua https://github.com/lunarmodules/luasystem
      ]
    )
  );
  systemd_traefik_configuration_provider =
    callPackage ./systemd_traefik_configuration_provider.nix
      { };
  # Upstream verifies a security key's signature but never looks at its user-presence bit, so the touch that sudo
  # relies on (sudo.nix) is enforced only on the client, where the flags in a key handle file can be edited. The patch
  # rejects a signature made without a touch, as sshd does, and adds the unit tests that run in the build.
  pam_rssh = pam_rssh.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./pam_rssh-require-user-presence.patch ];
  });
}
