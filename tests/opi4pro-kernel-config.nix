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
# file the kernel build already produced. The cost is the kernel itself, which CI builds and caches before the checks
# run, so this adds seconds rather than a cross-compile.
#
# This IS the assertion derivation rather than a wrapper around it, so there is no second copy of the symbol list and no
# redundant rebuild: adding an entry to kernelExtraEnabledSymbols extends this check automatically. It is built by
# `bootchainPkgs.buildPackages`, which is x86_64-linux, matching the platform the checks are evaluated for.

nixosConfigurations.opi4pro.config.system.build.opi4proKernelConfigAssertions
