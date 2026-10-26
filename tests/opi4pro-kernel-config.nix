{ nixosConfigurations, ... }:

# Covers the `kernelExtraEnabledSymbols` mechanism in modules/config-physical-opi4pro-common.nix: that every symbol the
# vendor kernel config asks for is still `=y` after `make oldconfig` has reconciled it.
#
# The failure this exists to catch is silent. vendorKernelConfig appends `CONFIG_X=y` to a flat file; `make oldconfig`
# then re-derives a self-consistent configuration and turns off anything whose dependencies are not met, without warning.
# The build succeeds either way. MD and NFSD were added that way and happened to stick; BLK_DEV_DM and DM_CRYPT are the
# riskier kind, because they did not appear in the vendor config at all until MD was enabled, and a symbol Kconfig has
# never heard of defaults to `n`.
#
# It also cannot be caught by booting anything: qemu has no Allwinner A733, so this kernel only ever runs on the board.
# Build time is the only place left.
#
# A derivation rather than a nixosTest, like flake-matrix: there is nothing to boot, and the assertion is a grep over a
# file the kernel build already produced. It reads `$out/config`, not the copy nixpkgs leaves in `$dev`: `$out` is in the
# system closure CI pushes to the cache, `$dev` is not, and Nix cannot build one output alone, so reading `$dev` cost a
# full kernel cross-compile even with the system kernel already cached.
#
# This IS the assertion derivation rather than a wrapper around it, so there is no second copy of the symbol list and no
# redundant rebuild: adding an entry to kernelExtraEnabledSymbols extends this check automatically. It is built by
# `bootchainPkgs.buildPackages`, which is x86_64-linux, matching the platform the checks are evaluated for.

nixosConfigurations.opi4pro.config.system.build.opi4proKernelConfigAssertions
