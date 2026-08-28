{
  config,
  lib,
  pkgs,
  ...
}:

# Secure Boot, and the TPM unlock that depends on it.
#
# Ported from the desktop's `/etc/nixos/modules/pcbase/modules/secureboot.nix`, which is where all of this was
# worked out. Most of what is NOT here was dropped on purpose: `measuredBoot` and systemd-pcrlock, the two lzbt
# patches that keep pcrlock able to explain a PCR 4 record, the unit that snapshots the booted boot loader's
# measurement, and the extra-ESP key mirroring. Every one of those exists to make PCR 4 workable, and PCR 4 is
# excluded here - nine issues were filed from that work and five are still open. What is left is the part with no
# outstanding upstream bugs: sign the boot chain, enrol owner keys, bind the disk to PCR 7.
#
# WHY THE TWO HALVES ARE SEPARATE SWITCHES. Enrolling the TPM against PCR 7 while Secure Boot is off binds the key
# to the fact that Secure Boot is off, so the machine would then unlock itself in exactly the state the enrolment
# was meant to detect. `tpmUnlock` therefore asserts on `enable`, and they are turned on one at a time so that a
# machine that fails to boot has one change to attribute it to.
let
  cfg = config.setup.secureBoot;
in
{
  # NO `imports` of lanzaboote here, deliberately. `imports` cannot depend on `config`, and a test node receives
  # `inputs` through `_module.args` rather than through specialArgs - so importing `inputs.lanzaboote...` from a
  # module that testNodes.base pulls in is an infinite recursion, which is exactly what it produced. The import
  # lives with the machine that has Secure Boot (config-physical-gmktec.nix, beside disko's), and the options
  # below are only ever *set* under `mkIf cfg.enable`, so a machine without that import and without the flag never
  # references an option that does not exist.
  options.setup.secureBoot = with lib; {
    enable = mkEnableOption ''
      Secure Boot through lanzaboote.

      Off everywhere by default, and it must stay that way: turning it on replaces systemd-boot with signed UKIs
      and enrols owner keys into the firmware, which a machine cannot recover from over ssh. Only a machine whose
      route back into firmware setup mode is known should have it
    '';

    pkiBundle = mkOption {
      type = types.str;
      default = "/var/lib/sbctl";
      description = ''
        Where the signing keys live ON THE MACHINE, in sbctl's layout - `GUID`, and `keys/{PK,KEK,db}/*.{key,pem}`.

        A path rather than anything derived from the store, because the private halves must not be world readable
        and `/nix/store` is. Whatever puts them there has to run before the bootloader install: sops-nix placing
        secrets with `path` does, since secrets are activated before `switch-to-configuration` reaches the
        bootloader.

        Without the private half no new generation can be signed, which means no new generation can boot.
      '';
    };

    configurationLimit = mkOption {
      type = types.nullOr types.int;
      default = config.boot.loader.systemd-boot.configurationLimit;
      defaultText = literalExpression "config.boot.loader.systemd-boot.configurationLimit";
      description = ''
        How many generations the boot menu offers, defaulting to whatever systemd-boot was already set to so that
        turning Secure Boot on does not silently change it.

        It matters more here than it did before: a lanzaboote generation is one UKI carrying kernel and initrd
        together, so each costs far more ESP space than the pair it replaces.
      '';
    };

    tpmUnlock = {
      enable = mkEnableOption ''
        unlocking the root device from the TPM instead of a typed passphrase.

        Separate from `enable` and asserted against it, because binding to PCR 7 is only meaningful once Secure
        Boot is actually on - see the header of this file
      '';

      pcrs = mkOption {
        type = types.listOf types.int;
        default = [ 7 ];
        description = ''
          Which PCRs the key is sealed against. 7 alone: it records the Secure Boot state and the enrolled keys,
          so it changes when someone turns Secure Boot off or enrols their own key, and does not change when a
          kernel is updated.

          PCR 4 is deliberately absent. It measures the boot loader and the UKI, so every generation changes it,
          and keeping a policy valid across generations needs systemd-pcrlock - which is the machinery this
          module exists without.
        '';
      };

      passphraseFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = literalExpression "config.sops.secrets.gmktec1_luks_passphrase.path";
        description = ''
          A file holding a passphrase that already opens the device, used to AUTHORISE the enrolment - not to
          unlock the disk at boot. Enrolling a new keyslot requires proving you can open an existing one, and
          there is nobody at the console of a server to type it.

          Null means the enrolment unit is not installed and `systemd-cryptenroll` is run by hand once, which is
          what PLAN_ENCRYPTION.md step 8c describes. Set it and the machine enrols itself, which is what makes a
          rebuilt machine come back with an automatic unlock rather than a passphrase prompt.

          The file lives on the encrypted root, so it is readable only by something that has already unlocked the
          disk. That is not circular: it cannot help an attacker boot the machine, and it can help the machine
          re-enrol after the TPM state changes.
        '';
      };

      devices = mkOption {
        type = types.listOf types.str;
        default = lib.mapAttrsToList (_: d: d.device) config.boot.initrd.luks.devices;
        defaultText = literalExpression "every device in boot.initrd.luks.devices";
        description = "The LUKS devices to enrol. Defaults to whatever the initrd unlocks.";
      };
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = cfg.tpmUnlock.enable -> cfg.enable;
          message = "setup.secureBoot.tpmUnlock needs setup.secureBoot.enable: sealing to PCR 7 with Secure Boot off binds the key to Secure Boot being off.";
        }
        {
          assertion = cfg.tpmUnlock.enable -> cfg.tpmUnlock.devices != [ ];
          message = "setup.secureBoot.tpmUnlock is on but there is no LUKS device to enrol - boot.initrd.luks.devices is empty.";
        }
      ];
    }

    (lib.mkIf cfg.enable {
      # lanzaboote REPLACES systemd-boot rather than sitting beside it; the module refuses to evaluate with both on.
      # mkForce because every physical machine here turns systemd-boot on explicitly.
      boot.loader.systemd-boot.enable = lib.mkForce false;
      boot.loader.efi.canTouchEfiVariables = true;

      boot.lanzaboote = {
        enable = true;
        inherit (cfg) pkiBundle configurationLimit;

        # The keys are owner-generated and come from sops; generating a fresh pair on the machine would produce keys
        # nothing else knows about, and a machine that can only be re-signed by itself is a machine that cannot be
        # rebuilt from this repository.
        autoGenerateKeys.enable = false;

        autoEnrollKeys = {
          enable = true;
          # NO MICROSOFT KEYS. One authority, which is the point of doing this at all: with the Microsoft CA
          # enrolled the firmware also trusts every shim and every option ROM Microsoft ever signed, and the
          # third-party CA in particular has signed bootloaders that will chain-load anything. The cost is that a
          # dGPU or an add-in card with a signed option ROM may stop initialising - which is a thing to discover on
          # a machine with onboard graphics and no add-in cards, i.e. this one.
          includeMicrosoftKeys = false;
        };
      };

      security.tpm2 = {
        enable = true;
        tctiEnvironment.enable = true;
      };

      environment.systemPackages = with pkgs; [
        sbctl
        tpm2-tools
      ];
    })

    # THE ENROLMENT, when a passphrase file is available to authorise it. Idempotent by inspection rather than by
    # a stamp file: it asks the header whether a tpm2 token is already there, so it does the right thing on a
    # machine that was enrolled by hand, on a rebuilt one, and on every ordinary boot in between.
    #
    # It does NOT wipe the passphrase slot. That slot is the only way in when the TPM refuses - after a firmware
    # update, a Secure Boot change, or a cleared TPM - and a machine whose sole key is sealed to a PCR is a
    # machine one BIOS update away from a restore.
    (lib.mkIf (cfg.tpmUnlock.enable && cfg.tpmUnlock.passphraseFile != null) {
      systemd.services.tpm-cryptenroll = {
        description = "Seal the root LUKS key to the TPM";
        wantedBy = [ "multi-user.target" ];
        after = [ "sops-install-secrets.service" ];
        unitConfig.ConditionPathExists = cfg.tpmUnlock.passphraseFile;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script =
          let
            pcrs = lib.concatMapStringsSep "+" toString cfg.tpmUnlock.pcrs;
          in
          lib.concatMapStringsSep "\n" (device: /* bash */ ''
            if [ "$(cryptsetup luksDump --dump-json-metadata ${lib.escapeShellArg device} | jq -r '.tokens | length')" != 0 ]; then
              echo "${device} already has a token, leaving it alone"
            else
              echo "Sealing ${device} to PCR ${pcrs}..."
              systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=${pcrs} \
                --unlock-key-file=${lib.escapeShellArg cfg.tpmUnlock.passphraseFile} \
                ${lib.escapeShellArg device}
            fi
          '') cfg.tpmUnlock.devices;
        path = with pkgs; [
          cryptsetup
          jq
          systemd
        ];
      };
    })
  ];
}
