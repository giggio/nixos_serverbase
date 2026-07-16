# Orange Pi 4 Pro - unattended SD installer image.
#
# This is the Orange Pi analog of the GMKTec ISO flow (mkIsoPackage in lib.nix), with two structural differences forced by the
# hardware and one by image size:
#
#   1. The install medium is an SD card, not a USB stick: the SoC's boot ROM can only fetch the first-stage loader from SD/eMMC
#      raw sectors. USB boot does not exist on this board.
#   2. The SD card is not ejected after installation - it stays in the board forever, holding the boot chain. The installer
#      therefore does not need to "get out of the way": nixos-install runs the target's bootloader hook inside the chroot
#      (NIXOS_INSTALL_BOOTLOADER=1 -> boot.loader.external.installHook), which overwrites the installer's own boot.scr on the
#      FAT partition with the final system's. The next boot lands in the installed system; no install loop is possible.
#   3. The image is LEAN: unlike the ISO, it does NOT embed the final system's closure (the base image is already ~6 GB and
#      growing; the SD card is 4 GB). It carries only the flake SOURCE, and nixos-install pulls the pre-built closure from the
#      attic cache over the network. The final system's closure must therefore be pushed to the cache BEFORE running the
#      installer - see the comment on the substituters below.
#
# There is no kexec into the installed system (the ISO flow does that): kexec on this vendor kernel is untested territory, and
# a plain reboot through the (now rewritten) boot chain is exactly the path the installed system will use forever after.
{
  lib,
  inputs,
}:

{
  # Builds the installer image package for one machine variant. Called from mkInstallerPackages in lib.nix for machines that set
  # `imgIsInstaller = true`. The resulting store path contains a single `<hostName><dev?>.img.zst`, which is what the Makefile's
  # img rule expects (same naming contract as mkSdCardImage, so the Makefile needs no changes).
  mkOpi4ProInstallerImage =
    {
      # nixpkgs for the TARGET architecture (aarch64) - only used for the final runCommand that links the image.
      pkgs,
      # The fully evaluated FINAL system (nixosConfigurations."opi4pro" or ."opi4prodev"). Referenced for exactly two things,
      # both with small closures: setup.hostName, and system.build.destroyFormatMount (the disko wipe/format/mount script).
      # Deliberately NOT referenced: system.build.toplevel - that would drag the entire final closure into the image.
      finalSystem,
      # The flake attribute the installer will install, e.g. "opi4pro" or "opi4prodev". Must exist in this flake's
      # nixosConfigurations, because the installer runs `nixos-install --flake /etc/nixos#<flakeAttr>`.
      flakeAttr,
      isDev,
      flake,
    }:
    let
      hostName = finalSystem.config.setup.hostName;

      installerSystem = lib.nixosSystem {
        modules = [
          (
            {
              config,
              pkgs,
              modulesPath,
              ...
            }:
            {
              imports = [
                # The full boot chain: vendor U-Boot, vendor kernel, boot.scr, the bootloader install hook. Everything the
                # installer needs to boot this board is the same as what the installed system needs.
                ./config-physical-opi4pro-common.nix
                # The SD image builder. Imported ONLY here (never by the final system): it hardcodes fileSystems."/" to the
                # NIXOS_SD label, which is correct for the installer (its root IS the SD card) and would collide with the
                # disko-managed NVMe root of the final system.
                "${modulesPath}/installer/sd-card/sd-image.nix"
                # sops-nix: lets the installer decrypt the same secrets the servers use, so the private cache address never has
                # to be hardcoded in this (world-readable) nix store path. See the sops block below.
                inputs.sops-nix.nixosModules.sops
              ];

              # ---------------------------------------------------------------------------------------------------------------
              # SD image layout. See config-physical-opi4pro-common.nix's header for the full disk map.
              # ---------------------------------------------------------------------------------------------------------------

              # The FAT partition holds Image + uInitrd + DTB + boot.scr (~65 MB of content). 256 MiB leaves headroom.
              sdImage.firmwareSize = 256;

              # 48 MiB. The FAT partition MUST start after the raw bootloader region: boot_package.fex is written at 16400 KiB
              # and is ~1.4 MB. The sd-image default of 8 MiB would put the filesystem directly underneath it, and the dd in
              # postBuildCommands would silently corrupt whatever file landed there (historically: "Bad Data CRC" on the
              # kernel).
              sdImage.firmwarePartitionOffset = 48;

              # Everything U-Boot loads lives on the FAT partition, INCLUDING boot.scr itself. This is the installer's own boot
              # script (config.system.build.* here is the installer's, so init= points at the installer toplevel). During
              # installation, nixos-install runs the bootloader hook inside the chroot, which overwrites these files with the
              # final system's - that is the handover mechanism.
              sdImage.populateFirmwareCommands = /* bash */ ''
                FWDIR="''${FWDIR:-$(pwd)/firmware}"
                mkdir -p "$FWDIR"
                cp -v "${config.boot.kernelPackages.kernel}/Image" "$FWDIR/Image"
                cp -v ${config.system.build.opi4proInitrdUImage}/uInitrd "$FWDIR/uInitrd"
                install -D -m 644 "${config.boot.kernelPackages.kernel}/dtbs/${config.hardware.deviceTree.name}" "$FWDIR/allwinner/sun60i-a733-orangepi-4-pro.dtb"
                cp -v ${config.system.build.opi4proBootScript} "$FWDIR/boot.scr"
              '';

              # The installer's root partition carries the flake SOURCE at /etc/nixos - this is what keeps the image small. The
              # heavy lifting (the final system's closure) is fetched from the attic cache by nixos-install at install time.
              # flake is this very flake's source tree (no .git directory), so the image rebuilds whenever the repo
              # changes, which is exactly right for an installer.
              sdImage.populateRootCommands = /* bash */ ''
                mkdir -p ./files/etc/nixos
                cp -r --no-preserve=mode,ownership ${flake}/. ./files/etc/nixos/
                chmod -R u+w ./files/etc/nixos
              '';

              sdImage.postBuildCommands = /* bash */ ''
                echo "Flashing locally built Allwinner boot0 and boot_package into the raw sectors..."
                # These offsets are fixed by the hardware/blob contract, not by us: the boot ROM reads boot0 from 8 KiB, and
                # boot0 reads the boot package from 16400 KiB (Armbian's write_uboot_platform() uses the same two offsets).
                dd if=${config.system.build.opi4proUboot}/boot0_sdcard.fex of=$img seek=8 conv=notrunc bs=1k
                dd if=${config.system.build.opi4proUboot}/boot_package.fex of=$img seek=16400 conv=notrunc bs=1k

                # CRITICAL: make partition 1 (FAT) the bootable one, and ONLY it. U-Boot's distro-boot logic runs
                # `part list mmc 0 -bootable devplist` and scans only the partitions in that list for boot.scr (under the
                # prefixes "/" and "/boot/"). sd-image.nix marks the ROOT partition bootable, which would make U-Boot scan the
                # ext4 root and never find our boot.scr on the FAT partition. `sfdisk --activate <img> 1` turns the bootable
                # flag ON for partition 1 and OFF for every other partition.
                sfdisk --activate $img 1
                echo "--- Partition table after activating partition 1 ---"
                sfdisk --list $img
              '';

              # ---------------------------------------------------------------------------------------------------------------
              # Secrets: the private cache address must NOT be hardcoded here.
              # ---------------------------------------------------------------------------------------------------------------
              # This image lands in the world-readable nix store, so the private cache host cannot appear in it. Instead we
              # decrypt it at runtime with sops-nix, exactly like the servers do (modules/serverbase). The secrets used:
              #   - nixExtraSecretOptions: an `extra-substituters = https://.../servers` line, pulled into nix.conf via the
              #     `!include` below (see nix.extraOptions). This is the same secret and mechanism the servers use.
              #   - attic_server + attic_token: assembled into a netrc so nix can AUTHENTICATE to the private cache. Without it,
              #     the cache answers 401 Unauthorized and nixos-install cannot substitute the closure.
              #   - attic_server (again): the bare cache hostname, read by the install script to poll for network readiness.
              # The age key that decrypts them is /etc/sops/age/server.agekey. It CANNOT go through nix (it would end up
              # world-readable in the store), so it is written straight into the SD image's ext4 root AFTER the build - see the
              # Makefile's out/nix/img/opi4pro.img.zst rule.
              sops = {
                defaultSopsFile = ./serverbase/secrets/shared.yaml;
                age = {
                  keyFile = "/etc/sops/age/server.agekey";
                  generateKey = false;
                };
                secrets.attic_server = { };
                secrets.attic_token = { };
                secrets.nixExtraSecretOptions = {
                  sopsFile = ./serverbase/secrets/nix_extra_options.conf;
                  format = "binary";
                };
                # Same netrc the servers build (modules/serverbase/secrets.nix): credentials for the private cache.
                templates.attic_netrc.content = ''
                  machine ${config.sops.placeholder.attic_server}
                  password ${config.sops.placeholder.attic_token}
                '';
              };

              # ---------------------------------------------------------------------------------------------------------------
              # Lean-image plumbing: where the final system's closure comes from.
              # ---------------------------------------------------------------------------------------------------------------
              # The closure MUST be in the cache before the installer runs, or nixos-install will try to build the vendor
              # kernel and U-Boot on the board (days, if it finishes at all). Push it from the build machine first:
              #   nix build .#nixosConfigurations.<flakeAttr>.config.system.build.toplevel --no-link --print-out-paths \
              #     | xargs nix store sign --key-file ~/.config/nix/giggio.key --recursive
              #   nix build .#nixosConfigurations.<flakeAttr>.config.system.build.toplevel --no-link --print-out-paths \
              #     | xargs attic push servers
              nix.settings = {
                experimental-features = [
                  "nix-command"
                  "flakes"
                ];
                # Setting `substituters` REPLACES the default list, so cache.nixos.org must be repeated explicitly. The private
                # cache is NOT listed here (it would leak the host into the store); it is appended at runtime via the
                # `extra-substituters` line in the sops-decrypted include below.
                substituters = [
                  "https://cache.nixos.org"
                ];
                # `trusted-public-keys` only holds public key material - no private host - so it is safe to keep in the clear:
                # the official key, the attic server key, and the local signing key (paths built on the PC and pushed are
                # signed with it).
                trusted-public-keys = [
                  "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
                  "servers:YRSK1sol6jQw7v0DRZhlGpzbJwvHENRRk6RTeuwE+Hs="
                  "giggio:gA25EMS+ouiC1xzWOKP68b7ikEfjmXohUT1PZ6aNP5c="
                ];
                # Credentials for the private cache (it requires auth - anonymous pulls get 401). Points at the runtime path of
                # the sops-decrypted netrc template above, mirroring modules/serverbase/default.nix.
                netrc-file = config.sops.templates.attic_netrc.path;
              };

              # Pull the private `extra-substituters` line into nix.conf at read time. `!include` is resolved by nix when it
              # runs (not baked into the store), so the path here is the runtime /run/secrets path sops-nix decrypts to. Mirrors
              # modules/serverbase/default.nix.
              nix.extraOptions = ''
                !include ${config.sops.secrets.nixExtraSecretOptions.path}
              '';

              networking.hostName = "${hostName}-installer";
              # Match the real servers: networkd as the backend (so DHCP-learned DNS is handed to resolved over D-Bus). Without
              # useNetworkd, networking.useDHCP selects the scripted dhcpcd path, which does not feed resolved when resolved owns
              # /etc/resolv.conf - the installer got an address but never learned the DNS server, so the internal cache host
              # never resolved.
              networking.useNetworkd = true;
              networking.useDHCP = true;
              services.resolved.enable = true;

              # This board has no battery-backed RTC, so it boots with a clock in the past. TLS verification against the binary
              # cache then fails with "certificate is not yet valid" because, from the board's point of view, every cert's
              # notBefore is in the future. Enable NTP and gate the installer on the clock actually being synchronised.
              services.timesyncd.enable = true;

              # If the install fails and drops to a login prompt, make it usable without credentials (this is a throwaway
              # installer environment on removable media, so an open root shell on the local console is acceptable and matches
              # how interactive NixOS installers behave).
              services.getty.autologinUser = "root";

              # ---------------------------------------------------------------------------------------------------------------
              # The unattended installation itself. Mirrors the ISO flow's unattended-install service (lib.nix), minus kexec.
              # ---------------------------------------------------------------------------------------------------------------
              systemd.services.unattended-install = {
                description = "Unattended NixOS installation to the NVMe SSD";
                wantedBy = [ "multi-user.target" ];
                after = [
                  "network-online.target"
                  "getty.target" # ensure getty.target has been processed so our Conflicts= below wins the console
                  "time-sync.target"
                ];
                wants = [
                  "network-online.target"
                  "time-sync.target"
                ];
                # Take over the consoles so progress is visible on HDMI and serial instead of a login prompt.
                conflicts = [
                  "getty@tty1.service"
                  "serial-getty@ttyS0.service"
                ];
                # If the installation FAILS, bring the login prompts back so the failure can be inspected on the spot
                # (journalctl -u unattended-install). Conflicts= stopped them when this service started; nothing would restart
                # them otherwise, leaving a board with no console.
                onFailure = [
                  "getty@tty1.service"
                  "serial-getty@ttyS0.service"
                ];
                path = [
                  pkgs.nix
                  pkgs.nixos-install-tools
                  pkgs.util-linux
                  pkgs.systemd
                  pkgs.coreutils
                  pkgs.getent
                  pkgs.git
                ];
                serviceConfig = {
                  Type = "oneshot";
                  StandardInput = "tty-force";
                };
                script = /* bash */ ''
                  echo '====== Orange Pi 4 Pro unattended installer (${flakeAttr}) ======'

                  echo '====== Waiting for the network (the final system closure comes from the cache)...'
                  # The cache host is secret, so read it at runtime from the sops-decrypted secret rather than hardcoding it.
                  cache_host="$(cat ${config.sops.secrets.attic_server.path})"
                  # network-online.target is best-effort with DHCP; poll until the cache host resolves, up to ~90s.
                  for i in $(seq 1 30); do
                    if getent hosts "$cache_host" > /dev/null; then break; fi
                    if [ "$i" = 30 ]; then
                      echo 'ERROR: network never came up / cache host does not resolve. Aborting before touching the NVMe.' >&2
                      exit 1
                    fi
                    sleep 3
                  done

                  echo '====== Waiting for the clock to be NTP-synchronised (no RTC on this board)...'
                  for i in $(seq 1 30); do
                    if timedatectl show -p NTPSynchronized --value | grep -q yes; then break; fi
                    if [ "$i" = 30 ]; then
                      echo 'ERROR: clock never synchronised; TLS to the cache would fail. Aborting.' >&2
                      exit 1
                    fi
                    sleep 2
                  done

                  echo '====== Wiping, partitioning, formatting and mounting /dev/nvme0n1 with disko...'
                  # This is the FINAL system's disko script (from config-physical-opi4pro.nix), embedded at image build time.
                  # Its closure is only the small disko tooling, not the system - the image stays lean.
                  ${finalSystem.config.system.build.destroyFormatMount}/bin/disko-destroy-format-mount --yes-wipe-all-disks

                  echo '====== Mounting the SD FAT partition into the target at /mnt/boot/firmware...'
                  # The final system's bootloader hook (run by nixos-install inside the chroot) writes the kernel, initrd, DTB
                  # and boot.scr to /boot/firmware - which inside the chroot is this bind mount. This is the moment the SD card
                  # stops booting the installer and starts booting the installed system.
                  mkdir -p /mnt/boot/firmware
                  mount --bind /boot/firmware /mnt/boot/firmware

                  echo '====== Installing NixOS from the flake (heavy paths substituted from the cache)...'
                  nixos-install --root /mnt --flake "/etc/nixos#${flakeAttr}" --no-root-passwd

                  echo '====== Installation complete. Rebooting into the installed system in 10 seconds...'
                  echo '====== (The SD card STAYS in the board: it carries the boot chain permanently.)'
                  sleep 10
                  reboot
                '';
              };

              system.stateVersion = "26.05";
            }
          )
        ];
      };

      file = "${hostName}${if isDev then "dev" else ""}.img.zst";
    in
    # Same output contract as mkSdCardImage: a directory containing exactly one <name>.img.zst, so the Makefile's img rule
    # (`nix build .#<name>_img` then `cp result/<name>.img.zst`) works unchanged.
    pkgs.runCommand file { } ''
      mkdir -p "$out"
      ln -s ${installerSystem.config.system.build.sdImage}/sd-image/*.img.zst $out/${file}
    '';
}
