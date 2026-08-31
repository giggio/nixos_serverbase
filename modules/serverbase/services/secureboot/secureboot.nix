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
  # lives with the machine that has Secure Boot (config-physical-gmktec.nix, beside disko's).
  #
  # THE OPTIONS ARE NOT HERE. They are in ./options.nix, which config-gmktec.nix imports for every variant of the
  # machine including `test`; this file is imported only where lanzaboote is. ./options.nix says why.
  imports = [ ./options.nix ];

  config = lib.mkMerge [
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

          # lanzaboote asserts `!allowBrickingMyMachine -> includeMicrosoftKeys`, so dropping the Microsoft CA
          # forces this on: with the flag off, `setup.secureBoot.enable = true` does not build at all. What it
          # actually does is pass `--yes-this-might-brick-my-machine` to `sbctl enroll-keys`, which skips sbctl's
          # refusal to enrol when it finds option ROMs the new db would no longer vouch for. The risk it names is
          # real and it is the SAME risk `includeMicrosoftKeys = false` was chosen with, stated once more by the
          # tool - not an additional one. It is acceptable here because this machine has onboard graphics, no
          # add-in cards and no dGPU, and because the way back is physical and known: AMI 2.22.1293, Security ->
          # Secure Boot -> Reset to Setup Mode.
          #
          # If a machine ever DOES fail to initialise something after enrolment, the fix is
          # `includeChecksumsFromTPM = true` (`--tpm-eventlog`), which enrols the hashes of the option ROMs that
          # actually ran into db - keeping one authority while letting that firmware through.
          allowBrickingMyMachine = true;
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
