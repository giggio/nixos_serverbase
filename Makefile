.PHONY: default start connect

.SECONDARY:
.SUFFIXES:
SHELL=bash

nix_deps = $(shell git ls-files --cached --modified --others --exclude-standard | sort | uniq | grep -v -e '^\..*' -e '.*\.md' -e Makefile | while IFS= read -r f; do [ -e "$$f" ] && echo "$$f"; done)
vm_count = $(shell (VBoxManage list vms | grep pitest || true) | awk '{gsub(/"/,""); print $$1}' | sed 's/pitest//' | sort --general-numeric-sort | tail -n-1)
out_dir := out
result_dir := .result
test_vms = $(shell nix run .#list_machines)
test_vms_files = $(shell for x in $(test_vms); do printf '$(out_dir)/%s-extra.txt ' "$$x"; done)

machines = $(shell nix run .#list_machines)
ova_with_agekey_files = $(shell for x in $(test_vms); do printf '$(out_dir)/nix/ova/%s-with-agekey.ova ' "$$x"; done)
ova_files = $(shell for x in $(test_vms); do printf '$(out_dir)/nix/ova/%s.ova ' "$$x"; done)
img_files = $(shell for x in $(test_vms); do printf '$(out_dir)/nix/img/%s.img.zst ' "$$x"; done)

clean:
	rm -rf "$(out_dir)" "$(result_dir)" result

deps:
	echo "These are the make build deps: $(nix_deps)"

$(ova_with_agekey_files): $(out_dir)/nix/ova/%-with-agekey.ova: $(out_dir)/nix/ova/.%.ova.stamp $(nix_deps)
	./inject-agekey-into-ova.sh "$(out_dir)/nix/ova/$*.ova" "$(out_dir)/nix/ova" # todo: simple test, remove

# The .stamp file is necessary because otherwise the timestamp of the ova file is the same as the
# timestamp of the nix build, which is unix time, 1-1-1970
# and making the %-with-agekey.ova file depend on the .ova would always rebuild everything.
# With the stamp file we have a file that has the correct date.
$(out_dir)/nix/ova/.%.ova.stamp: $(nix_deps)
	nix build .\#$*_virtualbox --print-build-logs --out-link "$(result_dir)/nix/ova/"
	mkdir -p "$(out_dir)/nix/ova/"
	ln -sf "$$(realpath --no-symlinks "$(result_dir)/nix/ova/$*.ova")" "$(out_dir)/nix/ova/$*.ova"
	touch --date=@$$(stat -c '%Y' "$(out_dir)/nix/ova/$*.ova") "$@"

$(ova_files): $(out_dir)/nix/ova/%.ova: $(out_dir)/nix/ova/.%.ova.stamp;

# See the comment above about the .stamp file
$(out_dir)/nix/img/.%.img.zst.stamp: $(nix_deps)
	nix build .\#$* --print-build-logs --out-link $(result_dir)/nix/img/
	mkdir -p "$(out_dir)/nix/img/"
	ln -sf "$$(realpath --no-symlinks "$(result_dir)/nix/img/$*.img.zst")" "$(out_dir)/nix/img/$*.img.zst"
	touch --date=@$$(stat -c '%Y' "$(out_dir)/nix/img/$*.img.zst") "$@"

$(img_files): $(out_dir)/nix/img/%.img.zst: $(out_dir)/nix/img/.%.img.zst.stamp;

import_%: $(out_dir)/nix/ova/%-with-agekey.ova
	up_if=$$(comm -12 <(ip -br link show up | awk '{ print $$1 }' | sort) <(for f in /sys/class/net/*/device; do echo $$f | awk -F/ '{ print $$5 }'; done | sort) | head -n1); \
	[ -z "$$up_if" ] && echo "no network interface is up" && exit 1; \
	vm_name="pitest$$(($(vm_count)+1))"; \
	echo "VM is $$vm_name"; \
	VBoxManage import $(out_dir)/nix/ova/$*-with-agekey.ova --vsys 0 --vmname=$$vm_name --cpus 4 --unit 7 --ignore; \
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
