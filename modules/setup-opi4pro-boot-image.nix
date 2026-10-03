# Orange Pi 4 Pro - BOOT-ONLY SD cards (card replacement, not installation).
#
# The SD card in an installed Orange Pi 4 Pro is not a system disk: the root filesystem lives on the NVMe, and the card only
# carries the boot chain, because the SoC's boot ROM can fetch the first-stage loader from SD/eMMC raw sectors and nowhere else.
# See the header of config-physical-opi4pro-common.nix for the full chain. What the card actually holds is:
#
#   raw sectors  : boot0 @ 8 KiB, boot_package (U-Boot + BL31 + SCP) @ 16400 KiB - no filesystem
#   partition 1  : FAT, label FIRMWARE, starts at 48 MiB, 3 GiB, MARKED BOOTABLE - boot.scr and the generation menu
#
# That is the whole card (the layout is in opi4pro-boot-files.nix). The installer image (setup-opi4pro.nix) additionally puts
# an ext4 root at partition 2, but that partition is the INSTALLER's own root and is dead weight the moment the installation
# finishes - nothing on the installed system ever mounts it.
#
# So replacing a dying card does NOT require reinstalling: it requires reproducing those two regions, and flashing one destroys
# nothing - the NVMe is never touched. There are two ways to get the menu onto the new card, and they differ in where the
# generations come from:
#
#   <machine>boot_card  `opi4pro-boot-card <ssh target> <out>` - THE NORMAL WAY. Reads the running board's generations over
#                       ssh (read-only) and builds a card with the same menu the board's own hook would write: the current
#                       system plus up to 20 older generations, every entry already on the NVMe by construction.
#   <machine>boot_img   A pure `nix build`, for when the board is down and cannot be asked. One menu entry: this flake
#                       revision's system. Its init= is an absolute /nix/store path, so THAT GENERATION MUST ALREADY EXIST ON THE
#                       NVMe or the entry boots to a stage-1 failure. Build it from the revision the board was running (deploy
#                       first, then build the card), and the paths match by construction.
# Either way, the next `nixos-rebuild switch` on the board rewrites the menu in place.
{
  # The image. Called from mkInstallerPackages in lib.nix for machines that set `imgIsInstaller = true` (i.e. machines whose
  # card carries only the boot chain). Produces a single `<hostName><dev?>boot.img.zst`, matching the naming contract of
  # mkSdCardImage/mkOpi4ProInstallerImage so the Makefile's generic img rule builds it unchanged.
  mkOpi4ProBootImage =
    {
      # nixpkgs for the BUILD machine (x86_64). The image is data: nothing in it runs on the build machine except the tools
      # that assemble it, and running them natively keeps a 3 GiB image from being written and compressed under emulation.
      pkgs,
      # The fully evaluated FINAL system (e.g. nixosConfigurations."opi4pronas"). Unlike the installer builder, this one
      # DELIBERATELY references system.build.toplevel: the menu's one entry is that exact generation. Only its kernel, initrd
      # and DTB are copied into the image; the closure itself stays on the NVMe.
      finalSystem,
      isDev,
    }:
    let
      cfg = finalSystem.config;
      bootFiles = import ./opi4pro-boot-files.nix {
        inherit pkgs;
        dtbName = cfg.hardware.deviceTree.name;
      };
      assembler = bootFiles.mkCardAssembler {
        boot0 = "${cfg.system.build.opi4proUboot}/boot0_sdcard.fex";
        bootPackage = "${cfg.system.build.opi4proUboot}/boot_package.fex";
      };
      file = "${cfg.setup.hostName}${if isDev then "dev" else ""}boot.img.zst";
    in
    pkgs.runCommand file { } /* bash */ ''
      mkdir -p "$out" firmware
      ${bootFiles.populateFirmware}/bin/opi4pro-populate-firmware firmware ${cfg.system.build.toplevel} 0
      ${assembler}/bin/opi4pro-assemble-card firmware "$out/${file}"
    '';

  # The from-board card builder, `opi4pro-boot-card <ssh target> <output.img.zst>`, with this machine's U-Boot. Run it on the
  # PC; see mkBootCardScript in opi4pro-boot-files.nix for what it reads and why.
  mkOpi4ProBootCard =
    {
      # nixpkgs for the machine the script runs on, the PC.
      pkgs,
      # The fully evaluated FINAL system. Only its U-Boot and DTB name are used; nothing of its toplevel.
      finalSystem,
    }:
    let
      cfg = finalSystem.config;
      bootFiles = import ./opi4pro-boot-files.nix {
        inherit pkgs;
        dtbName = cfg.hardware.deviceTree.name;
      };
    in
    bootFiles.mkBootCardScript {
      assembler = bootFiles.mkCardAssembler {
        boot0 = "${cfg.system.build.opi4proUboot}/boot0_sdcard.fex";
        bootPackage = "${cfg.system.build.opi4proUboot}/boot_package.fex";
      };
    };
}
