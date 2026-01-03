# Base NixOS server config for Raspberry Pi 4

## Developing

On a client machine you can develop and build a VirtualBox image (`.ova`) for testing, or build the `.iso` to install on the Raspberry Pi 4.
Clone this repo, and add the secret file to `/home/giggio/.config/nixos-secrets/server.agekey`.
In the future I might evolve it to be in a Git repository, but this is good enough for now.

1. Build it with `nix build .#vbox`. Image will be at: `./result/nixos.ova`.
2. Then run `./inject-agekey-into-ova.sh` to add the age key to the image.
   Resulting image will be at: `./result/nixos-with-agekey.ova`.
3. Import it into VirtualBox via `File > Import Appliance`.

## Deploying

1. Build it with `nix build .#pi4`. Image will be at: `./result/sd-image/nixos-img.zst`.
2. Burn it into the SD card using the Raspberry Pi Imager. For the operating system, select the last option, "Use custom"
   and select the image.
3. Load the sd card into the Raspberry Pi 4.

## License

TBD.
