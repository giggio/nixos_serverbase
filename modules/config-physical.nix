{
  options,
  lib,
  config,
  ...
}:

{
  # the guard is required only because vmboot also imports this module
  options.virtualisation = lib.attrsets.optionalAttrs (!config.setup.isVM) {
    fileSystems = options.fileSystems;
  };
}
