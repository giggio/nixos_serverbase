{ testNodes, pkgs, ... }:

# Covers modules/serverbase/services/firewall-fallback.nix: a firewall that cannot load leaves the machine closed, not
# open. The server's firewall is made to fail at boot the way a refused ruleset does, from systemd's side - the unit
# fails to start - by a precondition that holds only once the check creates a file. Then the peer probes it: ssh
# answers, a port the real firewall would open does not, and a closed one does not either. The server's own outbound
# connection still gets its answer, through connection tracking.
#
# Then the way out: the real firewall starts, its load removes the fallback tables in the same transaction, and the open
# port answers again. A fallback that outlived the firewall it stood in for would keep the machine shut after the fix.
let
  open = 8080;
  closed = 4444;
  peerPort = 9000;
  nc = "${pkgs.netcat-openbsd}/bin/nc";
in
{
  name = "firewall-fallback";

  nodes = {
    server = {
      imports = [ testNodes.base ];
      setup = {
        hostName = "nixos";
        username = "giggio";
      };
      networking.firewall.allowedTCPPorts = [ open ];
      systemd.services.nftables.serviceConfig.ExecStartPre =
        "${pkgs.coreutils}/bin/test -e /run/firewall-may-load";
    };
    peer.networking.firewall.enable = false;
  };

  testScript = /* python */ ''
    def vlan_address(machine):
        for line in machine.succeed("ip -4 -o addr show scope global").splitlines():
            if "inet 192.168." in line:
                return line.split("inet ")[1].split("/")[0]
        raise Exception(f"{machine.name} has no address on the test network")


    start_all()
    server.wait_for_unit("multi-user.target")
    peer.wait_for_unit("multi-user.target")
    server_address, peer_address = vlan_address(server), vlan_address(peer)
    for port in [${toString open}, ${toString closed}]:
        server.succeed(f"systemd-run --unit listener-{port} ${nc} -lk {port}")
        server.wait_for_open_port(port)
    peer.succeed("systemd-run --unit listener ${nc} -lk ${toString peerPort}")
    peer.wait_for_open_port(${toString peerPort})

    def reaches(port):
        return peer.execute(f"${nc} -z -w 3 {server_address} {port}")[0] == 0

    with subtest("the firewall failed to load, and the fallback took its place"):
        server.wait_for_unit("firewall-fallback.service")
        state = server.succeed("systemctl show -p ActiveState --value nftables.service").strip()
        assert state == "failed", f"nftables.service is {state}: the check did not break it"

    with subtest("closed but for ssh, and what the server asks for still answers"):
        assert reaches(22), "ssh is shut out by the fallback: the machine could not be reached to fix it"
        assert not reaches(${toString open}), "a port the real firewall opens is reachable without it"
        assert not reaches(${toString closed}), "a closed port is reachable with the firewall down"
        server.succeed(f"${nc} -z -w 3 {peer_address} ${toString peerPort}")

    with subtest("the real firewall starting again removes the fallback"):
        server.succeed("touch /run/firewall-may-load")
        server.succeed("systemctl start nftables.service")
        server.wait_for_unit("nftables.service")
        state = server.succeed("systemctl show -p ActiveState --value firewall-fallback.service").strip()
        assert state == "inactive", f"the fallback is still {state} with the firewall loaded"
        server.fail("${pkgs.nftables}/bin/nft list table ip fallback-firewall")
        server.fail("${pkgs.nftables}/bin/nft list table ip6 fallback-firewall")
        assert reaches(22) and reaches(${toString open}), "the open ports stay shut after the firewall came back"
        assert not reaches(${toString closed}), "a closed port is reachable with the firewall back"

    for machine in [server, peer]:
        (_, failed) = machine.systemctl("--failed --quiet")
        machine.log(f"systemctl --failed output: {failed}")
        assert "" == failed, "Expected no failed units and got: " + failed
  '';
}
