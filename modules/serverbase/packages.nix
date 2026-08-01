# The packages every server gets. Kept in its own file so that tests/base-packages.nix can assert over exactly this list
# instead of over the whole system closure, which is mostly NixOS defaults we do not control.
{ pkgs }:

with pkgs;
[
  # search with: nix search wget
  gnupg
  kitty # to add Kitty's terminfo
  neovim
  wget
  eza
  delta
  fzf
  githooks # Simple Git hooks manager https://github.com/gabyx/githooks
  htop
  mylua # see pkgs/default.nix
  gnumake
  cachix
  tree-sitter # An incremental parsing system for programming tools https://github.com/tree-sitter/tree-sitter
  marksman # Write Markdown with code assist and intelligence in the comfort of your favourite editor https://github.com/artempyanykh/marksman/
  markdownlint-cli2 # Fast, flexible, configuration-based command-line interface for linting Markdown/CommonMark files with the markdownlint library https://github.com/DavidAnson/markdownlint-cli2
  nixd # Nix language server https://github.com/nix-community/nixd/tree/main
  ripgrep # Line-oriented search tool that recursively searches your current directory for a regex pattern https://github.com/BurntSushi/ripgrep
  fd # Simple, fast and user-friendly alternative to find https://github.com/sharkdp/fd
  procs # A modern replacement for ps written in Rust https://github.com/dalance/procs
  python3
  gcc
  file
  tree
  bat
  jq
  nil # Language server for Nix https://github.com/oxalica/nil
  ghostty.terminfo
  lm_sensors
  zellij
]
