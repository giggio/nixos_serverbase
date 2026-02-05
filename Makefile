.SECONDARY:
.SUFFIXES:
SHELL=bash

# Include help system
include $(dir $(lastword $(MAKEFILE_LIST)))help.mk

nix_deps = $(shell git ls-files --cached --modified --others --exclude-standard | sort | uniq | grep -v -e '^\..*' -e '.*\.md' -e Makefile | while IFS= read -r f; do [ -e "$$f" ] && echo "$$f"; done)
define vm_count
$(shell (VBoxManage list vms | grep $(1) || true) | awk '{gsub(/"/,""); print $$1}' | sed 's/$(1)//' | sort --general-numeric-sort | tail -n-1)
endef
out_dir := out
out_dir_stamp := $(out_dir)/.stamp
out_nix_dir := $(out_dir)/nix
out_nix_dir_stamp := $(out_nix_dir)/.stamp
out_ova_dir := $(out_nix_dir)/ova
out_ova_dir_stamp := $(out_ova_dir)/.stamp
out_iso_dir := $(out_nix_dir)/iso
out_iso_dir_stamp := $(out_iso_dir)/.stamp
out_img_dir := $(out_nix_dir)/img
out_img_dir_stamp := $(out_img_dir)/.stamp
out_system_dir := $(out_nix_dir)/system
out_system_dir_stamp := $(out_system_dir)/.stamp
result_dir := $(out_dir)/.result
result_nix_dir := $(result_dir)/nix
result_ova_dir := $(result_nix_dir)/ova
result_iso_dir := $(result_nix_dir)/iso
result_img_dir := $(result_nix_dir)/img
result_system_dir := $(result_nix_dir)/system

.PHONY: default help $(out_dir) $(out_nix_dir) $(out_ova_dir) $(out_iso_dir) $(out_img_dir) $(out_system_dir)

machines_details = $(shell nix run .#list_machines)
machines = $(shell for x in $$(echo "$(machines_details)" | sed 's/|/\n/g' | grep '^machines ' | sed 's/^machines //'); do printf '%s ' "$$x"; done)
ova_files = $(shell for x in $$(echo "$(machines_details)" | sed 's/|/\n/g' | grep '^machines ' | sed 's/^machines //'); do printf '$(out_ova_dir)/%s.ova ' "$$x"; done)
ova_file_stamps = $(shell for x in $$(echo "$(machines_details)" | sed 's/|/\n/g' | grep '^machines ' | sed 's/^machines //'); do printf '$(out_ova_dir)/.%s.ova.stamp ' "$$x"; done)
img_files = $(shell for x in $$(echo "$(machines_details)" | sed 's/|/\n/g' | grep '^imgs ' | sed 's/^imgs //'); do printf '$(out_img_dir)/%s.img.zst ' "$$x"; done)
img_file_stamps = $(shell for x in $$(echo "$(machines_details)" | sed 's/|/\n/g' | grep '^imgs ' | sed 's/^imgs //'); do printf '$(out_img_dir)/.%s.img.zst.stamp ' "$$x"; done)
iso_files = $(shell for x in $$(echo "$(machines_details)" | sed 's/|/\n/g' | grep '^isos ' | sed 's/^isos //'); do printf '$(out_iso_dir)/%s.iso ' "$$x"; done)
iso_file_stamps = $(shell for x in $$(echo "$(machines_details)" | sed 's/|/\n/g' | grep '^isos ' | sed 's/^isos //'); do printf '$(out_iso_dir)/.%s.iso.stamp ' "$$x"; done)
machine_systems = $(shell for x in $$(echo "$(machines_details)" | sed 's/|/\n/g' | grep '^machines ' | sed 's/^machines //'); do printf '$(out_system_dir)/%s ' "$$x"; done)
machine_system_stamps = $(shell for x in $$(echo "$(machines_details)" | sed 's/|/\n/g' | grep '^machines ' | sed 's/^machines //'); do printf '$(out_system_dir)/.%s.stamp ' "$$x"; done)
architecture = $(shell uname -m)

out_disk_dir = $(out_dir)/disks
extra_iso = $(out_disk_dir)/secret-disk.iso

virtualbox_default_install_dir = $(shell VBoxManage list systemproperties | grep 'Default machine folder' | awk -F: '{ print $$2 }' | xargs echo)
up_if = $(shell up_if=$$(comm -12 <(ip -br link show up | awk '{ print $$1 }' | sort) <(for f in /sys/class/net/*/device; do echo $$f | awk -F/ '{ print $$5 }'; done | sort) | head -n1); if [ -z "$$up_if" ]; then echo "no network interface is up"; exit 1; else echo "$$up_if"; fi)

### Global Commands
## Clean all artifacts
clean:
	rm -rf "$(out_dir)" "$(result_dir)" result

## Print build dependencies
deps:
	@echo "These are the make build deps: $(nix_deps)"

# The .stamp file is necessary because otherwise the timestamp of the ova file is the same as the
# timestamp of the nix build, which is unix time, 1-1-1970
# and making other targets depend on the .ova would always rebuild everything.
# With the stamp file we have a file that has the correct date.
$(out_ova_dir)/.%.ova.stamp: $(nix_deps)
	nix build .\#$*_virtualbox_$(architecture)_ova --print-build-logs --out-link "$(result_ova_dir)/"
	mkdir -p "$(out_ova_dir)"
	ln -sf "$$(realpath "$(result_ova_dir)/$*.ova")" "$(out_ova_dir)/$*.ova"
	touch --date=@$$(stat -c '%Y' "$(out_ova_dir)/$*.ova") "$@"
	rm -rf "$(result_dir)"

### Build Artifacts
## Builds the OVA files
$(ova_files): $(out_ova_dir)/%.ova: $(out_ova_dir)/.%.ova.stamp;

# See the comment above about the .stamp file
$(out_img_dir)/.%.img.zst.stamp: $(nix_deps)
	nix build .\#$*_img --print-build-logs --out-link "$(result_img_dir)/"
	mkdir -p "$(out_img_dir)"
	ln -sf "$$(realpath "$(result_img_dir)/$*.img.zst")" "$(out_img_dir)/$*.img.zst"
	touch --date=@$$(stat -c '%Y' "$(out_img_dir)/$*.img.zst") "$@"
	rm -rf "$(result_dir)"

## Builds the image files
$(img_files): $(out_img_dir)/%.img.zst: $(out_img_dir)/.%.img.zst.stamp;

# See the comment above about the .stamp file
$(out_iso_dir)/.%.iso.stamp: $(nix_deps)
	nix build .\#$*_iso --print-build-logs --out-link "$(result_iso_dir)/"
	mkdir -p "$(out_iso_dir)"
	ln -sf "$$(realpath "$(result_iso_dir)/$*.iso")" "$(out_iso_dir)/$*.iso"
	touch --date=@$$(stat -c '%Y' "$(out_iso_dir)/$*.iso") "$@"
	rm -rf "$(result_dir)"

## Builds the ISO files
$(iso_files): $(out_iso_dir)/%.iso: $(out_iso_dir)/.%.iso.stamp;

# See the comment above about the .stamp file
$(out_system_dir)/.%.stamp: $(nix_deps)
	nix build .\#nixosConfigurations.$*.config.system.build.toplevel --print-build-logs --out-link "$(result_system_dir)/$*"
	mkdir -p "$(out_system_dir)"
	rm -f "$(out_system_dir)/$*"
	ln -sf "$$(realpath "$(result_system_dir)/$*")" "$(out_system_dir)/$*"
	touch --date=@$$(stat -c '%Y' "$(out_system_dir)/$*") "$@"
	rm -rf "$(result_dir)"

## Builds the systems files
$(machine_systems): $(out_system_dir)/%: $(out_system_dir)/.%.stamp;

## Create the cd disk ISO that holds the nixos secret key
$(extra_iso):
	@echo "Creating ISO $@..."
	mkdir -p "$$(dirname "$@")"
	xorriso -as mkisofs -o "$@" "$(HOME)/.config/nixos-secrets"

$(out_system_dir_stamp): $(machine_system_stamps)
	touch "$@"
## Builds all systems
$(out_system_dir) $(out_system_dir)/: $(out_system_dir_stamp)

$(out_iso_dir_stamp): $(iso_file_stamps)
	touch "$@"
## Builds all ISOs
$(out_iso_dir) $(out_iso_dir)/: $(out_iso_dir_stamp)

$(out_img_dir_stamp): $(img_file_stamps)
	touch "$@"
## Builds all images
$(out_img_dir) $(out_img_dir)/: $(out_img_dir_stamp)

$(out_ova_dir_stamp): $(ova_file_stamps)
	touch "$@"
## Builds all OVA filestems
$(out_ova_dir) $(out_ova_dir)/: $(out_ova_dir_stamp)

$(out_nix_dir_stamp): $(out_system_dir_stamp) $(out_iso_dir_stamp) $(out_img_dir_stamp) $(out_ova_dir_stamp)
	touch "$@"
## Buils all nix artifacts
$(out_nix_dir) $(out_nix_dir)/: $(out_nix_dir_stamp)

$(out_dir_stamp): $(out_nix_dir_stamp) $(extra_iso)
	touch "$@"
## Build the output directory
$(out_dir) $(out_dir)/: $(out_dir_stamp)

## Build all artifacts
all: $(out_nix_dir)

create_machines = $(shell for x in $$(echo "$(machines)" | sed 's/ /\n/'); do printf 'create_%s ' "$$x"; done)
create_%: vm_name=$*$(shell expr $(call vm_count,$*) + 1)
create_%: vm_dir=$(virtualbox_default_install_dir)/$(vm_name)
### VM Management
## Create a new VM
$(create_machines): create_%: $(out_iso_dir)/%.iso $(out_iso_dir)/.%.iso.stamp $(extra_iso)
	@echo "VM is $(vm_name)"
	@echo "VM dir will be $(vm_dir)"
	VBoxManage createvm --name=$(vm_name) --default --ostype=Linux26_64 --register
	VBoxManage modifyvm $(vm_name) --nic1 bridged --bridge-adapter1=$(up_if) --firmware=efi64 --cpus 4 --memory 4096 --audio-enabled=off
	VBoxManage storagectl $(vm_name) --name=IDE --controller=PIIX4 --remove
	VBoxManage storagectl $(vm_name) --name=NVMe --controller=NVMe --add=pcie --hostiocache=on
	VBoxManage createmedium disk --filename $(vm_dir)/$(vm_name).vmdk --size 20480
	VBoxManage storageattach $(vm_name) --storagectl=NVMe --port 0 --type=hdd --medium $(vm_dir)/$(vm_name).vmdk
	VBoxManage storageattach $(vm_name) --storagectl=SATA --port 0 --type=dvddrive --medium $$(realpath "$(out_iso_dir)/$*.iso")
	VBoxManage storageattach $(vm_name) --storagectl=SATA --port 1 --type=dvddrive --medium $(extra_iso)

import_machines = $(shell for x in $$(echo "$(machines)" | sed 's/ /\n/'); do printf 'import_%s ' "$$x"; done)
import_%: vm_name=$*$(shell expr $(call vm_count,$*) + 1)
## Import a VM from an OVA file
$(import_machines): import_%: $(out_ova_dir)/%.ova $(out_ova_dir)/.%.ova.stamp $(extra_iso)
	@echo "VM is $(vm_name)"
	VBoxManage import $(out_ova_dir)/$*.ova --vsys 0 --vmname=$(vm_name) --cpus 4 --unit 7 --ignore
	VBoxManage modifyvm $(vm_name) --nic1 bridged --bridge-adapter1=$(up_if) --uart1 0x3f8 4 --uartmode1 server /tmp/$(vm_name).sock
	VBoxManage storageattach $(vm_name) --storagectl=SATA --port 1 --type=dvddrive --medium $(extra_iso)

start_machines = $(shell for x in $$(echo "$(machines)" | sed 's/ /\n/'); do printf 'start_%s ' "$$x"; done)
start_%: vm_name=$*$(call vm_count,$*)
start_%: has_socket=$(shell VBoxManage showvminfo $(vm_name) --machinereadable | grep -q uartmode1= && echo true || echo false)
## Start a VM
$(start_machines): start_%:
	if [ "$*" == "$(vm_name)" ]; then echo "no VMs found" && exit 1; fi
	rm -f /tmp/$(vm_name).sock
	VBoxManage startvm $(vm_name) $$($(has_socket) && echo '--type headless' || echo '')
	if $(has_socket); then $(MAKE) connect_$*; fi

connect_machines = $(shell for x in $$(echo "$(machines)" | sed 's/ /\n/'); do printf 'connect_%s ' "$$x"; done)
connect_%: vm_name=$*$(call vm_count,$*)
connect_%: socket=/tmp/$(vm_name).sock
## Connect to a VM
$(connect_machines): connect_%:
	if [ "$*" == "$(vm_name)" ]; then echo "no VMs found" && exit 1; fi
	printf "Waiting for socket $(socket)..."
	for i in {1..5}; do if ! [ -S $(socket) ]; then printf '.'; sleep 1; else echo done; break; fi; done
	if ! [ -S $(socket) ]; then echo "no socket found" && exit 1; fi
	echo -e "\e[1;32m*** Exit with Ctrl + ] ***\e[0m"
	socat STDIO,raw,echo=0,escape=0x1d UNIX-CONNECT:$(socket)

delete_old_vms_machines = $(shell for x in $$(echo "$(machines)" | sed 's/ /\n/'); do printf 'delete_old_vms_%s ' "$$x"; done)
delete_old_vms_%: vm_numbers=$(shell (VBoxManage list vms | grep $*) | awk '{gsub(/"/,""); print $$1}' | sed 's/$*//' | sort --general-numeric-sort)
## This will delete old vms.
## It reads VMs with VBoxManage and deletes all but the last one.
$(delete_old_vms_machines): delete_old_vms_%:
	echo "$(vm_numbers)"
	if [ $$(echo "$(vm_numbers)" | wc -w) -lt 2 ]; then echo "No VMs to delete"; exit; fi;
	for vm_number in $$(echo "$(vm_numbers)" | sed 's/ /\n/g' | head -n-1); do \
	  vm=$$(printf '$*%s' "$$vm_number"); \
	  echo "Deleting VirtualBox VM: $$vm"; \
	  VBoxManage controlvm $$vm poweroff 2>/dev/null || true; \
	  VBoxManage unregistervm $$vm --delete-all; \
	done
	@echo "VMs left:"
	@VBoxManage list vms

### Tests
## Runs a quick boot test
test:
	nix build .#checks.$(architecture)-linux.boot-test --print-build-logs --no-link

### Information
## List machines
list_machines::
	@echo "Machines: $(machines)"

## List outputs
list_outputs:
	@echo "OVAs:" $(ova_files)
	@echo "ISOs:" $(iso_files)
	@echo "Imgs:" $(img_files)
	@echo "Disks:" $(extra_iso)
	@echo "Systems:" $(machine_systems)

## Shows flake information
flake_show:
	nix flake show

### Others
## Default target (do not use)
default:
	@echo "no default target"
	exit 1
