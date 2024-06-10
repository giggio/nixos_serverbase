{ config, pkgs, lib, ... }:

let
  repoUrl = "https://github.com/giggio/your-nixos-flake.git";
in
{
  systemd.services.clone-nixos-config = {
    description = "Clone the flake into /etc/nixos if absent";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = ''
        ${pkgs.bash}/bin/bash -eux -o pipefail -c '
          if [ ! -d /etc/nixos ] || [ -z "$(ls -A /etc/nixos 2>/dev/null || true)" ]; then
            rm -rf /etc/nixos
            ${pkgs.git}/bin/git clone --recurse-submodules ${repoUrl} /etc/nixos
            chown -R root:root /etc/nixos
          fi
        '
      '';
      RemainAfterExit = true;
    };
    # only run if /etc/nixos is missing or empty (negated condition)
    unitConfig = {
      ConditionPathExists = "!/etc/nixos";
    };
  };

  systemd.targets.multi-user.wants = [ "clone-nixos-config.service" ];
}
