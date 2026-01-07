# Reusable NixOS Server Configuration

This project provides a modular and reusable NixOS configuration, primarily
targeted at building server environments for Raspberry Pi 4 and VirtualBox
(testing).

It is structured as a Nix Flake that can be consumed by other projects to
inherit a base server configuration while allowing specific machine
customizations.

It can also run by itself for creating a default, base configuration.

## Architecture

- [modules/serverbase/](modules/serverbase/) (directory): The core reusable module (see [serverbase](serverbase)). It includes standard
  packages, Home Manager integration, encryption setup (SOPS), and general system
  settings.
- [modules/lib.nix](./modules/lib.nix): Provides helper functions to build system artifacts (Pi4 images,
  VBox OVAs) and development shells.
- [configuration.nix](./configuration.nix): A specific machine configuration (example: `pitest`)
  that imports the serverbase and applies host-specific settings.

## Usage as a flake (library)

You can import this project in your own `flake.nix` to build your custom servers.

### 1. In your `flake.nix` inputs

```nix
{
  inputs.serverbase = {
    url = "github:giggio/nixos_serverbase";
    inputs.nixpkgs.follows = "nixpkgs";
  };
};
```

### 2. Creating NixOS Configurations

Use `nixosModules.default` to get the base configuration (includes serverbase,
sops, and home-manager).

```nix
outputs = { nixpkgs, serverbase, ... }: {
  nixosConfigurations = {
    nixos = serverbase.nixosModules.lib.mkNixosSystem {
      system = "aarch64";
      modules = [ ./configuration.nix ];
      specialArgs = { }; # optional
      extraConfiguration = { }; # optional
    };
    nixos_virtuabox = serverbase.nixosModules.lib.mkNixosSystem {
      # .. the same as above, plus:
      system = "x86_64-linux"; # or "aarch64" if you are on an ARM machine
      virtualbox = true;
    };
  };
}
```

Available modules in `nixosModules`:

- `default`: Base list of modules (recommended).
- `lib`: Useful helper functions.
- `pi4`: Raspberry Pi 4 specific hardware config.
- `virtualbox`: VirtualBox specific hardware config.

### 3. Building Artifacts for deployment

You can build a Raspberry Pi 4 image that can be used to create an installation SD card.
You can also build a VirtualBox OVA that can be imported into VirtualBox.

```nix
outputs = { nixpkgs, serverbase, ... }: {
  packages.x86_64-linux = {
    nixos = self.nixosModules.lib.mkPi4Image {
      inherit pkgs;
      nixos-system = nixosConfigurations.nixos;
    };
    nixos_virtualbox = self.nixosModules.lib.mkVboxImage {
      inherit pkgs;
      nixos-system = nixosConfigurations."nixos_virtualbox";
    };
  };
}
```

## Direct Usage: Building the Default Configs

If you are using this repository directly to build the default machine (e.g.,
for testing or as a starting point):

### Developing with VirtualBox

1. Clone this repo and set up your secrets (see [Secrets](#secrets)).
2. Build and import the VM with `make import`.

The resulting OVA can be found in `out/nixos-with-agekey.ova`.

*Alternatively, import it manually.*

1. Build the vm with `make out/nixos-with-agekey.ova`.
2. Import the result into VirtualBox (`File > Import Appliance`).

The secrets will be automatically added to a separate disk in the VM during
the build process if using the provided scripts.

### Deploying to Raspberry Pi 4

1. Clone this repo and set up your secrets (see [Secrets](#secrets)).
2. Build it with `make out/nix/img/nixos.img.zst`.
   Or build with nix:

   ```bash
   nix build .#nixos --out-link out/nix/img/
   ```

3. Burn it into the SD card using the Raspberry Pi Imager. For the operating system,
   select the last option, "Use custom" and select the image.
4. Load the sd card into the Raspberry Pi 4.
5. Copy the secret file `server.agekey` to the root of a USB flash drive and connect
   the device to the Pi 4.

## Local Development Tools

### Entering the Dev Shell

Provides all necessary tools like SOPS, build utilities, etc.

```bash
nix develop
# or if you use direnv:
direnv allow
```

### Running Tests

Run the integrated NixOS verification tests (boots a VM and runs checks):

```bash
nix flake check
```

---

## Secrets

### Server key file

The sops secrets file should be at `$HOME/.config/nixos-secrets/server.agekey`.
Generate the key file with:

```bash
nix shell nixpkgs#age -c age-keygen -o $HOME/.config/nixos-secrets/server.agekey
```

Update the [.sops.yaml](.sops.yaml) with the key:

1. View public key: `grep public ~/.config/nixos-secrets/server.agekey`
2. Update `.sops.yaml` (automated helper):

```bash
key=$(grep public ~/.config/nixos-secrets/server.agekey | sed 's/.*: //')
sed -i -E "s/(.*pi4 )(.*)( #)/\$key\3/" .sops.yaml
```

### Gpg key

You need a gpg key to encrypt the secrets.
You can find your fingerprint with:

```bash
gpg --with-colons --fingerprint | awk -F: '$1 == "fpr" {print $10; exit}'
```

If you have more than one key, this will print multiple lines. Choose the key
that you need, or you can use all of them. Add the key to the
[.sops.yaml](.sops.yaml) file, replacing the one that is there under `giggio`.

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
