# The flakes home-manager-config is pinned to, read from its own flake.lock rather than declared as inputs here.
#
# That repository is written against nixos-unstable and home-manager master, and most of its commits after an input update
# are fixes for that update. Evaluating it against the servers' nixos-26.05 and home-manager release-26.05 would break on
# every one of them. Taking the exact revisions from its lock makes a submodule bump move the code and the inputs it was
# fixed against together, with nothing here to keep in step and nothing a `nix flake update` of this repository can move.
#
# Only these three: its fenix and llm-agents inputs are the PC's development tools, and leaving them out is what keeps
# pkgs/hm-pkgs.nix from fetching them (it merges them only when present).
lockFile:
let
  lock = builtins.fromJSON (builtins.readFile lockFile);
  # getFlake takes a flake reference string only. A narHash is base64, whose `+`, `/` and `=` have to be escaped to
  # survive as a query parameter.
  encode = builtins.replaceStrings [ "+" "/" "=" ] [ "%2B" "%2F" "%3D" ];
  lockedFlake =
    name:
    let
      locked = lock.nodes.${lock.nodes.root.inputs.${name}}.locked;
    in
    if locked.type != "github" then
      throw "hm-inputs.nix: ${name} is locked as ${locked.type}, only github inputs are handled"
    else
      builtins.getFlake "github:${locked.owner}/${locked.repo}/${locked.rev}?narHash=${encode locked.narHash}";
in
{
  nixpkgs = lockedFlake "nixpkgs";
  home-manager = lockedFlake "home-manager";
  sops-nix = lockedFlake "sops-nix";
}
