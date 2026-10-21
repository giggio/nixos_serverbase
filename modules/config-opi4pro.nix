{
  pkgs,
  lib,
  config,
  ...
}:

{
  imports = [ ];

  # The reverse path filter of the nftables firewall is a `fib` rule, and nothing promises the vendor kernel has the
  # modules for it: NFT_FIB_IPV4 and NFT_FIB_IPV6 are not in kernelExtraEnabledSymbols, they were off in the config the
  # board ran until 2026-10-20 and came back as modules with the config after it. On a kernel without them `nft -f`
  # refuses the whole ruleset at boot, and the board comes up with no firewall at all. The iptables firewall turned the
  # filter off by itself, reading the kernel's config, which nixpkgs cannot see for this kernel, so the board has never
  # had it; the nftables firewall does not look, and neither does its build-time check, which loads the rules into a
  # kernel of its own (lkl). Pinning the two symbols would turn it on at the cost of a kernel rebuild. Every variant
  # sets it, so the VM and the checks run the rules the board runs.
  networking.firewall.checkReversePath = false;

  boot = lib.mkMerge [
    {
      loader.systemd-boot.enable = lib.mkDefault false; # using grub and not UEFI
    }
    # Anywhere the board itself is not running - a VM or a test - the kernel is a hand-picked approximation of the one it
    # really uses. Tests have to make the same approximation as the VMs, otherwise they would be proving the behaviour of
    # a kernel this machine never runs.
    (lib.mkIf (config.setup.isVM || config.setup.isTest) {
      kernelPackages = pkgs.linuxPackages_6_6; # use same version as the one we can use on the board, see the physical configuration
    })
  ];
}
