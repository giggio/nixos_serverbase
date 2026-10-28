{ helpers, pkgs, ... }:
{
  # The mount check of a confined unit, which cannot run it in its own chroot; the instance is the escaped path. See
  # `helpers.systemd.mountCheckDependencies`. It waits for the mount as the unit did, or it runs at boot ahead of a mount
  # that is still coming and fails the unit with a dependency failure, which `Restart=` does not retry. No mount
  # namespace of its own: setting one up remounts every mount, the hung share this is meant to catch included, and the
  # check would hang there instead of in `timeout`. Root without capabilities, since systemd refuses to vouch for nobody.
  systemd.services."mount-check@" = {
    description = "Check that %f is mounted and answers";
    unitConfig.RequiresMountsFor = "%f";
    path = [
      pkgs.coreutils
      pkgs.gnugrep
    ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${
        pkgs.writeShellScript "mount-check" (helpers.systemd.checkMountScript [ ''"$1"'' ])
      } %f";
      NoNewPrivileges = true;
      CapabilityBoundingSet = [ "" ];
      PrivateNetwork = true;
    };
  };
}
