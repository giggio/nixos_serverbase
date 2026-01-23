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
  rust-toolchain-fenix = fenix.stable.defaultToolchain; # or fenix.complete.defaultToolchain, or beta. Rust toolchains.
  systemd_traefik_configuration_provider =
    callPackage ./systemd_traefik_configuration_provider.nix
      { };
}
