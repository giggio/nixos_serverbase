{ inputs, pkgs, ... }:

{
  imports = [
    inputs.nixos-hardware.nixosModules.gmktec-nucbox-g3-plus
    inputs.disko.nixosModules.disko
  ];

  boot.loader.systemd-boot.enable = true; # using UEFI and not GRUB

  systemd.services."serial-getty@ttyACM0" = {
    enable = true;
    wantedBy = [ "getty.target" ];
    overrideStrategy = "asDropin";
    environment.TERM = "vt102";
    serviceConfig.ExecStart = [
      ""
      "${pkgs.util-linux}/bin/agetty --login-program ${pkgs.shadow}/bin/login --issue-file /etc/issue:/etc/issue.d:/run/issue:/run/issue.d %I 115200"
    ];
  };

  services.udev.extraRules = ''
    KERNEL=="ttyACM0", TAG+="systemd", ENV{SYSTEMD_WANTS}="serial-getty@ttyACM0.service"
  '';

  disko.devices.disk.main = {
    device = "/dev/nvme0n1";
    type = "disk";
    preCreateHook = ''
      dd if=/dev/zero of="$device" bs=1M count=16 conv=fsync
    '';
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          type = "EF00";
          size = "512M";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        swap = {
          size = "4G";
          type = "8200";
          content.type = "swap";
        };
        nixos = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
