{ config, lib, ... }:

# sudo, and the ssh agent that answers it instead of a typed password.
#
# The PC runs a second ssh-agent that holds only FIDO2 keys (`ed25519-sk`) and reaches the servers through a
# RemoteForward to `agentSocket`, never through ForwardAgent. Its sudo key is trusted here and nowhere else, so pam_rssh
# asks it to sign a random challenge, the YubiKey blinks, a touch makes it root. Nothing on the server can log in
# anywhere with that key, and the login key never leaves the PC. The same agent carries a key the forge knows, which is
# what git on the servers pushes with - see `SSH_AUTH_SOCK` below.
#
# The password is still there behind it: no agent, no YubiKey, no touch before the FIDO timeout, and sudo asks for it as
# before. Connecting from anywhere that does not carry the forward (the phone) changes nothing.
let
  inherit (config.setup) username;
  # Pinned because the socket path needs it at evaluation time, and the PC's RemoteForward writes the same number. It
  # is what every server already had when this was written, allocated as the first normal user.
  uid = 1000;
  # A fixed path rather than whatever sshd's own forwarded agent is called: that name changes on every connection, so a
  # zellij pane opened after a reattach would hold a dead socket. With a fixed path the newest connection's forward is
  # the one found, which is also how the gpg-agent forward already behaves (StreamLocalBindUnlink, in default.nix).
  agentSocket = "/run/user/${toString uid}/ssh-remote-agent.sock";
in
{
  options.setup.sudoKeys = lib.mkOption {
    type = with lib.types; listOf str;
    default = [ ];
    description = ''
      Public keys, in authorized_keys format, whose signature through the forwarded agent is enough for `sudo`. Meant
      for FIDO2 keys (`sk-ssh-ed25519@openssh.com`), which need a touch per signature; a plain key here turns sudo
      into "whoever can reach the agent socket". Empty leaves sudo on the password alone.
    '';
  };

  config = {
    users.users.${username}.uid = uid;

    security.sudo-rs = {
      enable = true;

      # Non-interactive sudo over ssh, on ANY virtual machine. Keyed on setup.isVM rather than living in one hardware
      # module, because that is how it went wrong: the line was in config-virtual.nix, so the plain VM had it and the
      # vmboot variant - the only one that can rehearse anything involving a bootloader or the disko layout - did not.
      # The failure is `sudo: a terminal is required to read the password` from a scripted `ssh vm.localhost 'sudo …'`,
      # on the exact variant a rehearsal has to use.
      #
      # Convenience only, and it does not reach a real machine: setup.isVM is `setup.vm.enable`, which nothing but the
      # two virtual hardware modules sets.
      wheelNeedsPassword = lib.mkIf config.setup.isVM false;

      # sudo-rs' own default too, spelled out so it does not drift with a release. Per terminal - sudo-rs has no
      # `global` timestamp - so each new zellij pane costs one touch.
      extraConfig = "Defaults timestamp_timeout=15";
    };

    security.pam = {
      rssh = {
        enable = config.setup.sudoKeys != [ ];
        settings = {
          ssh_agent_addr = agentSocket;
          # $ruser is the one who ran sudo, not the target. Root-owned: a file the user could write, like the upstream
          # default of ~/.ssh/authorized_keys, would let anything running as the user add its own key and skip the
          # touch.
          auth_key_file = "/etc/ssh/sudo_keys/$ruser";
          # "Please touch the device.", since otherwise sudo just sits there while the key blinks on another desk
          cue = true;
        };
      };
      services.sudo.rssh = true;
      services.sudo-i.rssh = true;
    };

    environment.etc."ssh/sudo_keys/${username}" = lib.mkIf (config.setup.sudoKeys != [ ]) {
      text = lib.concatLines config.setup.sudoKeys;
    };

    # git on the servers pushes through the same forwarded agent. A session from the PC has no SSH_AUTH_SOCK of its own,
    # since ForwardAgent is off for the servers, so point it at the fixed socket. A session that did forward an agent -
    # from another client - keeps it; sshd's SetEnv is not used for this because it is applied after the forwarded
    # agent's variable and would replace it.
    environment.extraInit = ''
      if [ -z "''${SSH_AUTH_SOCK:-}" ] && [ "$(id -u)" = ${toString uid} ]; then
        export SSH_AUTH_SOCK=${agentSocket}
      fi
    '';

    # Every push costs a touch, and a superproject push with its submodule is two connections. The master connection
    # makes that one touch per ten minutes. While it lives, anything running as the user can reach the forge through it
    # without a touch; that is the price, and it is bounded by the persist time. Matched on the forge's ssh user rather
    # than a host name, so no host has to be written here.
    programs.ssh.extraConfig = ''
      Match user forgejo,git
        ControlMaster auto
        ControlPath /run/user/%i/ssh-control-%C
        ControlPersist 10m
    '';
  };
}
