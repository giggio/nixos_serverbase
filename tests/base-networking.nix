{ testNodes, ... }:

# Covers the networking block of modules/serverbase/default.nix. The firewall is the part worth proving from outside, so
# a second plain node sits on the same network and probes the server: a firewall that is merely "active" tells you
# nothing about whether it lets the right traffic through.
{
  name = "base-networking";

  nodes = {
    server = {
      imports = [
        testNodes.base
        {
          setup = {
            hostName = "nixos";
            username = "giggio";
          };
        }
      ];
    };

    # deliberately not a serverbase machine: it only needs to be somewhere else on the network
    peer = { };
  };

  testScript = /* python */ ''
    def vlan_address(machine):
        # only the 192.168.x.x address is on the network shared with the other node; every node also carries qemu's own
        # 10.0.2.15 user-mode address, and probing that would just be probing the prober
        for line in machine.succeed("ip -4 -o addr show scope global").splitlines():
            if "inet 192.168." in line:
                return line.split("inet ")[1].split("/")[0]
        raise Exception(f"{machine.name} has no address on the test network")


    start_all()
    server.wait_for_unit("multi-user.target")
    peer.wait_for_unit("multi-user.target")

    with subtest("the network is managed by networkd and nothing else"):
        server.wait_for_unit("systemd-networkd.service")
        server.wait_for_unit("systemd-networkd-wait-online.service")
        server.fail("systemctl cat NetworkManager.service")
        server.fail("systemctl cat wpa_supplicant.service")

    with subtest("interfaces keep their plain names"):
        links = server.succeed("ip -o link show").strip()
        assert " eth" in links, f"no eth* interface, so predictable names are still on: {links}"

    with subtest("docker bridges and wireless stations are left alone by networkd"):
        for name, match in [("01-docker", "Name=docker*"), ("01-wlan0", "WLANInterfaceType=station")]:
            definition = server.succeed(f"cat /etc/systemd/network/{name}.network").replace(" ", "")
            assert match.replace(" ", "") in definition, \
                f"{name}.network does not match on {match}: {definition}"
            assert "Unmanaged=yes" in definition, \
                f"{name}.network does not mark its links unmanaged: {definition}"

    with subtest("the host calls itself by its derived name"):
        hostname = server.succeed("hostname").strip()
        # a test build is also a dev build, so the derived name carries the dev suffix
        assert hostname == "nixosdev", f"the host calls itself '{hostname}', expected 'nixosdev'"

    # addressed directly rather than by name: the driver's /etc/hosts entries are keyed on each node's networking.hostName,
    # which serverbase derives, so the node known as "server" here answers to "nixosdev"
    server_address = vlan_address(server)

    with subtest("the firewall is up and answers pings"):
        server.wait_for_unit("firewall.service")
        peer.succeed(f"ping -c 1 -W 5 {server_address}")

    with subtest("the firewall lets ssh in and keeps everything else out"):
        peer.succeed(f"timeout 5 bash -c 'echo > /dev/tcp/{server_address}/22'")
        peer.fail(f"timeout 5 bash -c 'echo > /dev/tcp/{server_address}/4444'")

    for machine in [server, peer]:
        (_, failed) = machine.systemctl("--failed --quiet")
        machine.log(f"systemctl --failed output: {failed}")
        assert "" == failed, "Expected no failed units and got: " + failed
  '';
}
