{ testNodes, ... }:

# Covers modules/serverbase/services/systemd_traefik_configuration_provider.nix together with the drop-ins
# helpers.systemd.mkSystemdPackageForTraefik generates - the two halves only mean something as a pair. Every service in
# the sibling repository that is reachable from outside is published this way, so what is proven here is the mechanism:
# a unit that carries traefik labels gets a routing file while it runs, and loses it when it stops.
#
# The directory the files land in is created by the traefik module in the *other* repository, so the test creates it the
# same way that module does; what belongs to this repository is the provider, not traefik itself.
let
  dynamicConfigDir = "/etc/traefik/dynamic";
  host = "myapp";
  domain = "example.test";
  port = 8080;
  serviceName = "myapp-server";
  # a unit with no labels at all, to show the provider publishes only what asks to be published
  unlabelledServiceName = "plain-server";
in
{
  name = "traefik-provider";

  nodes.machine =
    {
      config,
      pkgs,
      helpers,
      ...
    }:
    {
      imports = [
        testNodes.base
        {
          setup = {
            hostName = "nixos";
            username = "giggio";
          };
        }
      ];

      services = {
        traefik = {
          enable = true;
          staticConfigOptions.providers.file = {
            directory = dynamicConfigDir;
            watch = true;
          };
        };
        systemd_traefik_configuration_provider.enable = true;
      };

      systemd = {
        tmpfiles.rules = [ "d ${dynamicConfigDir} 0750 root traefik -" ];

        services = {
          ${serviceName} = {
            description = "A service that wants to be reachable from outside";
            wantedBy = [ "multi-user.target" ];
            serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
          };
          ${unlabelledServiceName} = {
            description = "A service that is nobody's business but its own";
            wantedBy = [ "multi-user.target" ];
            serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
          };
        };

        packages = [
          (helpers.systemd.mkSystemdPackageForTraefik {
            inherit
              pkgs
              host
              port
              serviceName
              domain
              ;
            isDev = config.setup.isDev;
          })
        ];
      };
    };

  testScript = # python
    ''
      machine.wait_for_unit("multi-user.target")

      routing_file = "${dynamicConfigDir}/${serviceName}.service.yml"

      with subtest("the provider and traefik are both up"):
          machine.wait_for_unit("traefik.service")
          machine.wait_for_unit("systemd_traefik_configuration_provider.service")

      with subtest("a labelled service is published while it runs"):
          machine.wait_for_unit("${serviceName}.service")
          machine.wait_for_file(routing_file)
          routing = machine.succeed(f"cat {routing_file}")
          machine.log(f"published routing:\n{routing}")

          assert "Host(`${host}.${domain}`)" in routing, f"the router does not match the host: {routing}"
          assert "http://127.0.0.1:${toString port}" in routing, \
              f"the router does not point back at the service's port: {routing}"
          assert "websecure" in routing, f"the router is not on the TLS entrypoint: {routing}"
          assert "*.${domain}" in routing, f"the wildcard certificate is not requested: {routing}"
          # the labels are written under `traefik.`, and the provider is expected to strip that prefix: a file that
          # still had it would be silently ignored by traefik
          assert routing.lstrip().startswith("http:"), \
              f"the routing file is not rooted at traefik's `http` section: {routing}"

      with subtest("a test build also publishes the plain http router"):
          # setup.environment is "test", so this is the isDev branch of the drop-in: reachable without a certificate
          assert "${host}_insecure" in routing, f"the dev-only insecure router is missing: {routing}"

      with subtest("a service that carries no labels is not published"):
          machine.wait_for_unit("${unlabelledServiceName}.service")
          machine.fail("test -e ${dynamicConfigDir}/${unlabelledServiceName}.service.yml")

      with subtest("stopping the service withdraws its routing"):
          machine.succeed("systemctl stop ${serviceName}.service")
          machine.wait_until_fails(f"test -e {routing_file}")

      with subtest("starting it again publishes it back"):
          machine.succeed("systemctl start ${serviceName}.service")
          machine.wait_for_file(routing_file)

      (_, failed) = machine.systemctl("--failed --quiet")
      machine.log(f"systemctl --failed output: {failed}")
      assert "" == failed, "Expected no failed units and got: " + failed
    '';
}
