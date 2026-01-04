# Base NixOS server config for Raspberry Pi 4

On a client machine you can develop and build a VirtualBox image (`.ova`) for
testing, or build the `.img.zst` image to install on the Raspberry Pi 4.

## Developing

Clone this repo, and add the secret file (see [the Secrets section bellow](#secrets)).

1. Build and import the vm with `make import`.

Or do it manually...

1. Build the vm with `make out/nixos-with-agekey.ova`.
2. Import it into VirtualBox via `File > Import Appliance`.

The secrets will be automatically added to a separate disk in the VM.

## Deploying

1. Build it with `make out/nix/img/nixos.img.zst`.
2. Burn it into the SD card using the Raspberry Pi Imager. For the operating system,
   select the last option, "Use custom" and select the image.
3. Load the sd card into the Raspberry Pi 4.
4. Copy the secret file `server.agekey` to the root of a USB flash drive and connect
   the device to the Pi 4.

## Secrets

### Server key file

The sops secrets file should be at `$HOME/.config/nixos-secrets/server.agekey`.
Generate the key file with:

```bash
nix shell nixpkgs#age -c age-keygen -o $HOME/.config/nixos-secrets/server.agekey
```

After that, you need to update the file at [.sops.yaml](.sops.yaml) with the key.
View it with:

```bash
grep public ~/.config/nixos-secrets/server.agekey
```

Update the `.sops.yaml` file with the key with:

```bash
key=`grep public ~/.config/nixos-secrets/server.agekey | sed 's/.*: //'`
sed -i -E "s/(.*pi4 )(.*)( #)/\$key\3/" .sops.yaml
```

### Gpg key

You need a gpg key to encrypt the secrets.
You can find your fingerprint with:

```bash
gpg --with-colons --fingerprint | awk -F: '$1 == "fpr" {print $10; exit}'
```

If you have more than one key, this will print multiple lines. Choose the key
that you need, or you can use all of them.
Add the key to the `.sops.yaml` file, replacing the one that is there under `giggio`.

### Editing the secrets file

The secrets file is at [./secrets/shared.yaml](./secrets/shared.yaml).
You can edit it with:

```bash
sops secrets/shared.yaml # if using the flake default shell with `nix develop` or `direnv`
# or
nix run nixpkgs#sops secrets/shared.yaml # if not using the flake default shell
```

You will need to use one of the keys listed in the [.sops.yaml](.sops.yaml) file.
If you don't have it, remove the file and create a new one.

You can find the file layout by looking at [./secrets.nix](./secrets.nix).

## License

TBD.
