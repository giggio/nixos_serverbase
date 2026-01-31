{ ... }:
{
  network.proxyNetwork = rec {
    name = "proxy";
    serviceName = "docker-network-${name}";
    service = "${serviceName}.service";
    targetName = "${serviceName}-root";
    target = "${targetName}.target";
  };
}
