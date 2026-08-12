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
          content = {
            type = "swap";
            # Encrypted with a key generated fresh at every boot, and never stored anywhere.
            #
            # Swap is a hole straight through any other encryption on this machine. The kernel pages whatever is in
            # RAM out to it - decrypted database rows, session tokens, key material that a service had open - and
            # 4 G of that sits on the same disk in the clear. Encrypting application state while leaving swap
            # readable protects the copy on disk and leaves the copy next to it.
            #
            # A random per-boot key is the right shape here because it costs nothing: no keyslot, no passphrase, no
            # dependency on the key server, and nothing to lose or recover. The only thing it rules out is
            # hibernation, which needs the swap contents to survive a power cycle - and these are servers that never
            # hibernate.
            randomEncryption = true;
          };
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
