{
  pkgs,
  testNodes,
  ...
}:

# Covers modules/helpers/clevis.nix - `helpers.clevis.decryptToRuntimeScript`, the preStart that turns a JWE bound to
# a tang server into a plaintext file under a unit's RuntimeDirectory.
#
# The fixture is a NixOS node running `services.tang`, while the real key server is a Debian box. That mismatch does
# not weaken the test: tang is a protocol, the server is stateless, and every part that can break lives on the CLIENT
# - whether clevis is on PATH, whether the unit can reach the network at the point preStart runs, whether the
# plaintext lands with the right ownership and mode, whether it is cleaned up, and above all what happens when the
# server is not there. Booting Debian to assert those would test Debian.
#
# Three things are asserted, and the third is the one that matters:
#
#   1. A JWE decrypts, the plaintext is correct, and it is 0600 owned by the unit's user.
#   2. RuntimeDirectory really does take it away again when the unit stops. This is the improvement over the sops
#      secret it replaces - that one sits in /run/secrets from boot to shutdown, this one exists only while the job
#      runs.
#   3. With tang unreachable the unit FAILS - promptly, loudly, and without hanging. "Degrade, not wedge" is the
#      property the plan asks for: a backup job that cannot reach tang must report a failure that reaches Telegram,
#      not block forever holding a timer, and not silently succeed against an empty config.
#
# The JWE is built at runtime rather than baked in, because it can only be produced against a live tang server, and
# a fixture JWE would pin a key that this test's server does not have.

let
  tangPort = 7500;
  secretText = "this-is-the-secret-config";
  plaintextPath = "/run/clevis-consumer/decrypted.conf";
in
{
  name = "clevis-unlock";

  nodes = {
    # The key server. `ipAddressAllow` mirrors what the real appliance does with its socket drop-in and nftables, so
    # the test also proves the client is not accidentally relying on an unrestricted server.
    tang =
      { ... }:
      {
        imports = [ testNodes.base ];
        setup = {
          hostName = "tang";
          username = "giggio";
        };
        services.tang = {
          enable = true;
          listenStream = [ (toString tangPort) ];
          # Localhost as well as the test subnet. IPAddressAllow is a whitelist and does NOT imply loopback, so
          # without this the node cannot reach its own port - which is what `wait_for_open_port` does, and it
          # times out looking exactly like a tang server that failed to start. The real appliance needs the same
          # line for `tang-show-keys`; see appliances/tang/Automation_Custom_Script.sh.
          ipAddressAllow = [
            "192.168.1.0/24"
            "localhost"
          ];
        };
        networking.firewall.allowedTCPPorts = [ tangPort ];
      };

    client =
      { helpers, ... }:
      {
        imports = [ testNodes.base ];
        setup = {
          hostName = "client";
          username = "giggio";
        };
        # jose and curl explicitly: the test script computes the tang thumbprint by hand, the way a human would
        # before pinning it, and clevis does not put its own dependencies on the system PATH.
        environment.systemPackages = with pkgs; [
          clevis
          jose
          curl
        ];

        systemd.services.clevis-consumer = {
          description = "reads a tang-bound JWE the way a backup job does";
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            RuntimeDirectory = "clevis-consumer";
            # A dedicated user, so the mode/ownership assertions mean something rather than passing because
            # everything runs as root.
            User = "clevisuser";
            Group = "clevisuser";
          };
          # clevis, jose and curl together: clevis decrypt is a shell script that calls the other two.
          path = with pkgs; [
            clevis
            jose
            curl
            coreutils
          ];
          preStart = helpers.clevis.decryptToRuntimeScript {
            jwe = "/var/lib/clevis-test/secret.jwe";
            out = plaintextPath;
            # Short, so the negative case fails inside the test's patience instead of the default 75 seconds.
            attempts = 2;
            delaySeconds = 1;
          };
          script = ''
            test -s ${plaintextPath}
            echo "consumed: $(cat ${plaintextPath})"
          '';
        };

        users.users.clevisuser = {
          isSystemUser = true;
          group = "clevisuser";
        };
        users.groups.clevisuser = { };

        # The JWE is written here by the test script once tang is up. Readable by the unit's user; it is inert
        # without the server, which is the entire premise.
        systemd.tmpfiles.rules = [ "d /var/lib/clevis-test 0755 root root -" ];

      };
  };

  # A function, so the tang node's address can be interpolated. The node NAME is deliberately not used: this base
  # configuration runs networkd with resolved, which does not pick up the test driver's /etc/hosts entries, so
  # `http://tang:7500` fails to resolve (curl exit 6) in a way that reads like a dead server. The address is stable
  # within a test and is what the real clients use anyway - they pin an IP, not a name.
  testScript =
    { nodes, ... }: # python
    ''
      tang_addr = "${nodes.tang.networking.primaryIPAddress}"

      start_all()
      tang.wait_for_unit("tangd.socket")
      tang.wait_for_open_port(${toString tangPort})
      client.wait_for_unit("multi-user.target")

      with subtest("the advertisement is reachable from the client"):
          adv = client.succeed("curl -sf http://" + tang_addr + ":${toString tangPort}/adv")
          assert '"payload"' in adv, f"not a JWS advertisement: {adv!r}"

      with subtest("a JWE bound to tang decrypts into the unit's RuntimeDirectory"):
          # `-y` trusts the advertisement without prompting. The real bindings pin `thp` instead, and must - without
          # it a spoofed tang server on the LAN would be accepted. That pinning is verified against the REAL server
          # by appliances/tang/verify.sh, which is where it belongs: here there is one server, created by this test,
          # so pinning its own key would assert nothing while dragging a fragile `jose` pipeline into the fixture.
          # What this test is for is the client half - decrypt, ownership, cleanup, and failure with tang gone.
          client.succeed(
              "echo -n '${secretText}'"
              f" | clevis encrypt tang '{{\"url\":\"http://{tang_addr}:${toString tangPort}\"}}' -y"
              " > /var/lib/clevis-test/secret.jwe"
          )
          # Inert on disk: the JWE must not contain the plaintext anywhere.
          jwe = client.succeed("cat /var/lib/clevis-test/secret.jwe")
          assert "${secretText}" not in jwe, "the JWE leaks its plaintext"

          client.succeed("systemctl start clevis-consumer.service")
          assert "${secretText}" == client.succeed("cat ${plaintextPath}").strip()

      with subtest("the plaintext is private to the unit's user"):
          mode_owner = client.succeed("stat -c '%a %U' ${plaintextPath}").strip()
          assert mode_owner == "600 clevisuser", f"expected 600 clevisuser, got {mode_owner}"

      with subtest("RuntimeDirectory takes the plaintext away when the unit stops"):
          client.succeed("systemctl stop clevis-consumer.service")
          client.fail("test -e ${plaintextPath}")
          client.fail("test -e /run/clevis-consumer")

      with subtest("with tang unreachable the unit fails rather than hanging"):
          tang.shutdown()
          # `systemctl start` on a failing oneshot returns non-zero, so this both proves the failure and bounds the
          # time: a wedged preStart would hit the test driver's timeout instead and fail loudly there.
          client.fail("systemctl start clevis-consumer.service")
          state = client.succeed("systemctl show -p Result --value clevis-consumer.service").strip()
          client.log(f"unit Result: {state}")
          assert state != "success", f"the unit reported success with tang down: {state}"
          # And it must not leave a partial or stale file behind for the next run to trust.
          client.fail("test -e ${plaintextPath}")

          journal = client.succeed("journalctl -u clevis-consumer.service --no-pager | tail -20")
          assert "tang" in journal.lower(), f"the failure does not mention tang: {journal!r}"
    '';
}
