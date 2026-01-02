# Base server config

## Developing

On a client machine you can develop and build a VirtualBox image (`.ova`) for testing, or build the `.iso` to install on the Raspberry Pi 4.
Clone this repo, and add the secret file to `/home/giggio/.config/nixos-secrets/server.agekey`.
In the future I might evolve it to be in a Git repository, but this is good enough for now.

Build it with:

```bash
nix build .#vbox
```

## Testing

Import the machine into VirtualBox and run it (File > Import Appliance).

## Deploying

TBD.
