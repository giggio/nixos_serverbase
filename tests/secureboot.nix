{
  inputs,
  lib,
  testNodes,
  ...
}:

# Covers modules/serverbase/services/secureboot.nix, and specifically the half of it that a rehearsal on real
# hardware cannot cheaply answer: does a LUKS device sealed to the TPM actually open with NO passphrase, and does
# the passphrase slot survive the sealing?
#
# That second question is the one with teeth. `systemd-cryptenroll` will happily wipe the slot you enrolled from,
# and a machine whose only key is sealed to a PCR is a machine one firmware update away from a restore - PCR 7
# changes when Secure Boot state or the enrolled keys change, which is exactly what a BIOS update does. The unit
# under test never passes `--wipe-slot`, and this proves it rather than trusting the absence of a flag.
#
# WHAT THIS CANNOT SHOW YOU: Secure Boot itself. A nixosTest node boots through `-kernel`/`-initrd` with no
# bootloader at all, so nothing here signs a UKI, installs lanzaboote or enrols a PK - and PCR 7 in a software TPM
# reads whatever swtpm says it does rather than what real firmware would measure. The signing half is proven by
# the VM rehearsal in PLAN_ENCRYPTION.md step 8b, on OVMF with a real variable store. What IS proven here is the
# enrolment logic, its idempotency, and the unlock.
let
  container = "/var/lib/test-luks.img";
  mapper = "testcrypt";
  passphraseFile = "/etc/test-luks-passphrase";
  passphrase = "correct-horse";
in
{
  name = "secureboot";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [
        testNodes.base
        # config-physical-gmktec.nix imports both of these on the real machine; a test node has no machine
        # module, so the test supplies them. Here `inputs` is a plain argument of the test file rather than
        # something the module system has to resolve, so there is no recursion.
        inputs.lanzaboote.nixosModules.lanzaboote
        ../modules/serverbase/services/secureboot.nix
        {
          setup = {
            hostName = "machine";
            username = "giggio";
          };
        }
      ];

      virtualisation = {
        tpm.enable = true;
        # the container is a file on the root disk, and 1 GiB of default is not enough to hold it comfortably
        diskSize = 4096;
      };

      environment.systemPackages = with pkgs; [
        cryptsetup
        jq
        tpm2-tools
      ];

      environment.etc."test-luks-passphrase" = {
        text = passphrase;
        mode = "0400";
      };

      # The module's own unit, pointed at a device this test makes rather than at a real root. `enable` has to
      # come with it - the module asserts that tpmUnlock without it is a configuration error, which is the point -
      # so lanzaboote is turned back off by force, because a test node has no bootloader for it to install into.
      setup.secureBoot = {
        enable = true;
        tpmUnlock = {
          enable = true;
          inherit passphraseFile;
          devices = [ container ];
        };
      };
      boot.lanzaboote.enable = lib.mkForce false;
      boot.loader.grub.enable = lib.mkForce false;

      # ...but not at boot, because the container does not exist until the test makes it. The test starts it by
      # hand once there is something to enrol.
      systemd.services.tpm-cryptenroll.wantedBy = lib.mkForce [ ];
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    with subtest("a TPM is actually present, or everything below would pass vacuously"):
        machine.succeed("test -c /dev/tpmrm0")
        machine.succeed("tpm2_pcrread sha256:7")

    with subtest("a LUKS container to enrol"):
        machine.succeed("truncate -s 128M ${container}")
        machine.succeed(
            "cryptsetup luksFormat -q --type luks2 "
            "--pbkdf pbkdf2 --pbkdf-force-iterations 1000 "
            "--key-file ${passphraseFile} ${container}"
        )
        slots = machine.succeed("cryptsetup luksDump ${container} | grep -cE '^\\s+[0-9]+: luks2'").strip()
        assert slots == "1", f"expected one keyslot before enrolling, got {slots}"

    with subtest("the module's unit seals it to the TPM"):
        machine.succeed("systemctl start tpm-cryptenroll.service")
        machine.require_unit_state("tpm-cryptenroll.service", "active")
        tokens = machine.succeed(
            "cryptsetup luksDump --dump-json-metadata ${container} | jq -r '.tokens | length'"
        ).strip()
        assert tokens != "0", "no token was added, so nothing was sealed to the TPM"
        kind = machine.succeed(
            "cryptsetup luksDump --dump-json-metadata ${container} | jq -r '.tokens[\"0\"].type'"
        ).strip()
        assert kind == "systemd-tpm2", f"the token is a {kind}, not a systemd-tpm2 one"

    with subtest("the passphrase slot SURVIVED - the machine is not one BIOS update from a restore"):
        machine.succeed("cryptsetup luksOpen --test-passphrase --key-file ${passphraseFile} ${container}")

    with subtest("and the container opens with no passphrase at all"):
        machine.succeed("systemd-cryptsetup attach ${mapper} ${container} - tpm2-device=auto")
        machine.succeed("test -b /dev/mapper/${mapper}")
        machine.succeed("systemd-cryptsetup detach ${mapper}")

    with subtest("running it again changes nothing, so a rebuilt machine does not re-enrol"):
        before = machine.succeed("cryptsetup luksDump ${container} | sha256sum")
        machine.succeed("systemctl restart tpm-cryptenroll.service")
        after = machine.succeed("cryptsetup luksDump ${container} | sha256sum")
        assert before == after, "the unit is not idempotent - it touched an already-enrolled header"
        machine.succeed(
            "journalctl -u tpm-cryptenroll.service | grep -q 'already has a token'"
        )
  '';
}
