{ config, lib, ... }:

# The OPTIONS half of ./secureboot.nix, split out for one reason: every variant of a machine with Secure Boot has
# to be able to SET `setup.secureBoot`, but only the variants that carry lanzaboote can carry the half that
# defines `boot.lanzaboote`.
#
# `lib.mkIf false` still requires the option it defines to EXIST, so a module that says
# `boot.lanzaboote = mkIf cfg.enable {...}` cannot be evaluated anywhere lanzaboote is absent - which includes
# every nixosTest node, since those take a machine's `test` hardware variant and the test driver builds its own
# boot path. Without this split, either the option is missing on test nodes (`The option
# nodes.machine.setup.secureBoot does not exist`) or `boot.lanzaboote` is (`The option
# nodes.machine.boot.lanzaboote does not exist`). Both were seen, one after the other, on 2026-08-30.
#
# So: this file goes wherever the machine goes - config-gmktec.nix, which all four variants import. ./secureboot.nix
# goes beside lanzaboote's own module, in config-physical-gmktec.nix.
#
# The assertions live here rather than next to the config, because they are about the CONFIGURATION being coherent
# and should fire on a test node too.
let
  cfg = config.setup.secureBoot;
in
{
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

  config.assertions = [
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
