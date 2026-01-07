.PHONY: default start connect

SHELL=bash

nix_deps := $(shell git ls-files --cached --modified --others --exclude-standard | sort | uniq | grep -v '^\..*')
vm_count := $(shell (VBoxManage list vms | grep pitest || true) | awk '{gsub(/"/,""); print $$1}' | sed 's/pitest//' | sort --general-numeric-sort | tail -n-1)

clean:
	rm -rf out

out/nix/ova/%.ova: $(nix_deps)
	nix build .\#$*_virtualbox --print-build-logs --out-link out/nix/ova/

out/%-with-agekey.ova: out/nix/ova/%.ova $(nix_deps)
	./inject-agekey-into-ova.sh out/nix/ova/$*.ova out

out/nix/img/%.img.zst: $(nix_deps)
	nix build .\#$* --print-build-logs --out-link out/nix/img/

import_%: out/%-with-agekey.ova
	up_if=$$(comm -12 <(ip -br link show up | awk '{ print $$1 }' | sort) <(for f in /sys/class/net/*/device; do echo $$f | awk -F/ '{ print $$5 }'; done | sort) | head -n1); \
	[ -z "$$up_if" ] && echo "no network interface is up" && exit 1; \
	vm_name="pitest$$(($(vm_count)+1))"; \
	echo "VM is $$vm_name"; \
	VBoxManage import out/$*-with-agekey.ova --vsys 0 --vmname=$$vm_name --cpus 4 --unit 7 --ignore; \
	VBoxManage modifyvm $$vm_name --nic1 bridged --bridge-adapter1=$$up_if --uart1 0x3f8 4 --uartmode1 server /tmp/$$vm_name.sock

start:
	[ -z "$(vm_count)" ] && echo "no VMs found" && exit 1; \
	vm_name="pitest$(vm_count)"; \
	rm -f /tmp/$$vm_name.sock; \
	VBoxManage startvm $$vm_name --type headless; \
	$(MAKE) connect

connect:
	[ -z "$(vm_count)" ] && echo "no VMs found" && exit 1; \
	vm_name="pitest$(vm_count)"; \
	socket=/tmp/$$vm_name.sock; \
	printf "Waiting for socket $$socket..."; \
	for i in {1..5}; do if ! [ -S $$socket ]; then printf '.'; sleep 1; else echo done; break; fi; done; \
	! [ -S $$socket ] && echo "no socket found" && exit 1; \
	echo -e "\e[1;32m*** Exit with Ctrl + ] ***\e[0m"; \
	socat STDIO,raw,echo=0,escape=0x1d UNIX-CONNECT:$$socket

default:
	echo "no default target"
	exit 1
