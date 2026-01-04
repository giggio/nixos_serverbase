.PHONY: default vb_import

nix_deps := $(git ls-files --cached --modified --others --exclude-standard | sort | uniq | grep -v '^\..*')

out/nix/ova/nixos.ova: $(nix_deps)
	nix build .\#vbox --print-build-logs --out-link out/nix/ova/

out/nixos-with-agekey.ova: out/nix/ova/nixos.ova $(nix_deps)
	./inject-agekey-into-ova.sh out/nix/ova/nixos.ova out

out/nix/img/nixos.img.zst:
	nix build .\#pi4 --print-build-logs --out-link out/nix/img/

vb_import:
	echo "Will import into VirtualBox, todo..."

default:
	echo "no default target"
	exit 1
