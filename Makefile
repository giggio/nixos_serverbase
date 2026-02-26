.SECONDARY:
.SUFFIXES:
SHELL=bash
ifndef VMS_DIR
  $(error VMS_DIR is undefined)
endif

# Include help system
include $(dir $(lastword $(MAKEFILE_LIST)))help.mk

nix_deps = $(shell git ls-files --cached --modified --others --exclude-standard | sort | uniq | grep -v -e '^\..*' -e '.*\.md' -e Makefile | while IFS= read -r f; do [ -e "$$f" ] && echo "$$f"; done)
define vm_count
$(shell find $(VMS_DIR) -type d -name '$(1)*' -printf '%f\n' | sed 's/$(1)//' | sort --general-numeric-sort | tail -n-1)
endef
out_dir := out
out_dir_stamp := $(out_dir)/.stamp
out_nix_dir := $(out_dir)/nix
out_nix_dir_stamp := $(out_nix_dir)/.stamp
out_vm_dir := $(out_nix_dir)/vm
out_vm_dir_stamp := $(out_vm_dir)/.stamp
out_iso_dir := $(out_nix_dir)/iso
out_iso_dir_stamp := $(out_iso_dir)/.stamp
out_img_dir := $(out_nix_dir)/img
out_img_dir_stamp := $(out_img_dir)/.stamp
out_system_dir := $(out_nix_dir)/system
out_system_dir_stamp := $(out_system_dir)/.stamp
out_disks_dir := $(out_dir)/disks
out_disks_dir_stamp := $(out_disks_dir)/.stamp
result_dir := $(out_dir)/.result
result_nix_dir := $(result_dir)/nix
result_vm_dir := $(result_nix_dir)/vm
result_iso_dir := $(result_nix_dir)/iso
result_img_dir := $(result_nix_dir)/img
result_system_dir := $(result_nix_dir)/system

.PHONY: default help $(out_dir) $(out_nix_dir) $(out_iso_dir) $(out_img_dir) $(out_system_dir)

machines_details = $(shell nix run .#list_machines)
machines = $(shell for x in $$(echo "$(machines_details)" | sed 's/|/\n/g' | grep '^machines ' | sed 's/^machines //'); do printf '%s ' "$$x"; done)
vm_files = $(shell for x in $$(echo "$(machines_details)" | sed 's/|/\n/g' | grep '^machines ' | sed 's/^machines //'); do printf '$(out_vm_dir)/run-%s-vm ' "$$x"; done)
vm_file_stamps = $(shell for x in $$(echo "$(machines_details)" | sed 's/|/\n/g' | grep '^machines ' | sed 's/^machines //'); do printf '$(out_vm_dir)/.run-%s-vm.stamp ' "$$x"; done)
img_files = $(shell for x in $$(echo "$(machines_details)" | sed 's/|/\n/g' | grep '^imgs ' | sed 's/^imgs //'); do printf '$(out_img_dir)/%s.img.zst ' "$$x"; done)
img_file_stamps = $(shell for x in $$(echo "$(machines_details)" | sed 's/|/\n/g' | grep '^imgs ' | sed 's/^imgs //'); do printf '$(out_img_dir)/.%s.img.zst.stamp ' "$$x"; done)
iso_files = $(shell for x in $$(echo "$(machines_details)" | sed 's/|/\n/g' | grep '^isos ' | sed 's/^isos //'); do printf '$(out_iso_dir)/%s.iso ' "$$x"; done)
iso_file_stamps = $(shell for x in $$(echo "$(machines_details)" | sed 's/|/\n/g' | grep '^isos ' | sed 's/^isos //'); do printf '$(out_iso_dir)/.%s.iso.stamp ' "$$x"; done)
machine_systems = $(shell for x in $$(echo "$(machines_details)" | sed 's/|/\n/g' | grep '^machines ' | sed 's/^machines //'); do printf '$(out_system_dir)/%s ' "$$x"; done)
machine_system_stamps = $(shell for x in $$(echo "$(machines_details)" | sed 's/|/\n/g' | grep '^machines ' | sed 's/^machines //'); do printf '$(out_system_dir)/.%s.stamp ' "$$x"; done)
architecture = $(shell uname -m)

out_disk_dir = $(out_dir)/disks
secrets_qcow2 = $(out_disk_dir)/secret-disk.qcow2
empty_qcow2 = $(out_disk_dir)/empty.qcow2

vms_dir = $(shell echo $$VMS_DIR)
up_if = $(shell up_if=$$(comm -12 <(ip -br link show up | awk '{ print $$1 }' | sort) <(for f in /sys/class/net/*/device; do echo $$f | awk -F/ '{ print $$5 }'; done | sort) | head -n1); if [ -z "$$up_if" ]; then echo "no network interface is up"; exit 1; else echo "$$up_if"; fi)

### Global Commands
## Clean all artifacts
clean:
	rm -rf "$(out_dir)" "$(result_dir)" result

## Print build dependencies
deps:
	@echo "These are the make build deps: $(nix_deps)"

### Build Artifacts

# The .stamp file is necessary because otherwise the timestamp of the run-...-vm file is the same as the
# timestamp of the nix build, which is unix time, 1-1-1970
# and making other targets depend on the run-...-vm file would always rebuild everything.
# With the stamp file we have a file that has the correct date.
$(out_vm_dir)/.run-%-vm.stamp: $(nix_deps)
	nix build .\#$*_$(architecture)_vm --print-build-logs --out-link "$(result_vm_dir)/"
	mkdir -p "$(out_vm_dir)"
	ln -sf "$$(realpath "$(result_vm_dir)/run-$*-vm")" "$(out_vm_dir)/run-$*-vm"
	touch --date=@$$(stat -c '%Y' "$(out_vm_dir)/run-$*-vm") "$@"
	rm -rf "$(result_dir)"

## Builds the vm files
$(vm_files): $(out_vm_dir)/run-%-vm: $(out_vm_dir)/.run-%-vm.stamp;

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

## Create the qcow2 disk that holds the nixos secret key
GUESTFISH_CMD="run;\
mount /dev/sda1 /;\
mkdir-p /nixos-secrets;\
upload $(HOME)/.config/nixos-secrets/server.agekey /nixos-secrets/server.agekey;\
chmod 0400 /nixos-secrets/server.agekey;\
sync;\
exit"
$(secrets_qcow2):
	@echo "Creating secrets qcow2 $@..."
	mkdir -p "$$(dirname "$@")"
	qemu-img create -f qcow2 $@ 4M
	virt-format -a $@ --filesystem=ext4
	echo -e $(subst ;,\n,${GUESTFISH_CMD}) | sudo guestfish -a $@

$(empty_qcow2):
	@echo "Creating empty qcow2 $@..."
	mkdir -p "$$(dirname "$@")"
	qemu-img create -f qcow2 "$@" 48G
	# virt-format -a "$@" --filesystem=ext4

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

$(out_vm_dir_stamp): $(vm_file_stamps)
	touch "$@"
## Builds all VM filestems
$(out_vm_dir) $(out_vm_dir)/: $(out_vm_dir_stamp)

$(out_nix_dir_stamp): $(out_system_dir_stamp) $(out_iso_dir_stamp) $(out_img_dir_stamp) $(out_vm_dir_stamp)
	touch "$@"
## Buils all nix artifacts
$(out_nix_dir) $(out_nix_dir)/: $(out_nix_dir_stamp)

$(out_disks_dir_stamp): $(empty_qcow2) $(secrets_qcow2)
	touch "$@"
## Buils all disks
$(out_disks_dir) $(out_disks_dir)/: $(out_disks_dir_stamp)

$(out_dir_stamp): $(out_nix_dir_stamp) $(out_disks_dir_stamp)
	touch "$@"
## Build the output directory
$(out_dir) $(out_dir)/: $(out_dir_stamp)

## Build all artifacts
all: $(out_dir)

start_new_from_iso_machines = $(shell for x in $$(echo "$(machines)" | sed 's/ /\n/'); do printf 'start_new_from_iso_%s ' "$$x"; done)
start_new_from_iso_%: vm_name=$*$(shell expr $(call vm_count,$*) + 1)
start_new_from_iso_%: vm_dir=$(VMS_DIR)/$(vm_name)
start_new_from_iso_%: TMPDIR:=$(shell mktemp -d nix-vm.XXXXXXXXXX --tmpdir)
start_new_from_iso_%: disk_path=$(vm_dir)/$(vm_name).qcow2
start_new_from_iso_%:
### VM Management
## Create and starts a new VM that does not yet have an installation and will be installed via ISO (slower)
$(start_new_from_iso_machines): start_new_from_iso_%: $(out_iso_dir)/%.iso $(out_iso_dir)/.%.iso.stamp $(secrets_qcow2) $(empty_qcow2)
	@echo -e "VM is \e[32m$(vm_name)\e[0m (at \e[32m$(vm_dir)\e[0m)"
	mkdir -p "$(vm_dir)"
	cp $(secrets_qcow2) "$(vm_dir)/secret-disk.qcow2"
	cp $(empty_qcow2) $(disk_path)
	mkdir -p "$(TMPDIR)/xchg"
	dd if=/dev/zero of=$(vm_dir)/ovmf_vars_$(vm_name).fd bs=64K count=1
	cp "$$(realpath $$(dirname $$(realpath $$(which qemu-system-x86_64)))/../share/qemu)/edk2-x86_64-code.fd" $(vm_dir)/edk2-x86_64-code.fd
	@echo -e "Stop the VM when the installation is done and then run with \e[32mmake start_$*\e[0m."
	@echo "#!/bin/bash\nqemu-system-x86_64 -machine type=q35 -machine accel=kvm -cpu max \\\n\
	  -name $* \\\n\
	  -m 8192 \\\n\
	  -enable-kvm \\\n\
	  -smp 4 \\\n\
	  -drive if=pflash,format=raw,unit=0,file="$(vm_dir)/edk2-x86_64-code.fd",readonly=on \\\n\
	  -drive if=pflash,format=raw,unit=1,file="$(vm_dir)/ovmf_vars_$(vm_name).fd" \\\n\
	  -device virtio-rng-pci \\\n\
	  -nic user,ipv6=off,model=virtio,mac=52:54:00:CA:FE:EE,hostfwd=tcp::2222-:22,"$QEMU_NET_OPTS" \\\n\
	  -virtfs local,path=$(TMPDIR)/xchg,security_model=none,mount_tag=shared \\\n\
	  -virtfs local,path=$(TMPDIR)/xchg,security_model=none,mount_tag=xchg \\\n\
	  -blockdev driver=file,filename="$(disk_path)",node-name=file1 \\\n\
	  -blockdev driver=qcow2,file=file1,node-name=hd0 \\\n\
	  -blockdev driver=file,filename=$(vm_dir)/secret-disk.qcow2,node-name=secretsfile \\\n\
	  -blockdev driver=qcow2,file=secretsfile,node-name=hd_secrets \\\n\
	  -device nvme,id=nvme0,serial=1234 \\\n\
	  -device nvme-ns,drive=hd0,nsid=1,bus=nvme0 \\\n\
	  -device nvme-ns,drive=hd_secrets,nsid=2,bus=nvme0 \\\n\
	  -device virtio-keyboard \\\n\
	  -usb \\\n\
	  -device usb-tablet,bus=usb-bus.0 \\\n\
	  -serial unix:/tmp/$(vm_name).sock,server,nowait \\\n\
	  \$$QEMU_OPTS" > "$(vm_dir)/run-$*-vm"
	sed -i 's/\\n/\n/g' "$(vm_dir)/run-$*-vm"
	chmod +x "$(vm_dir)/run-$*-vm"
	qemu-system-x86_64 -machine type=q35 -machine accel=kvm -cpu max \
	  -name $* \
	  -m 8192 \
	  -enable-kvm \
	  -cdrom $$(realpath "$(out_iso_dir)/$*.iso") \
	  -boot order=c,once=d \
	  -smp 4 \
	  -drive if=pflash,format=raw,unit=0,file="$(vm_dir)/edk2-x86_64-code.fd",readonly=on \
	  -drive if=pflash,format=raw,unit=1,file="$(vm_dir)/ovmf_vars_$(vm_name).fd" \
	  -device virtio-rng-pci \
	  -nic user,ipv6=off,model=virtio,mac=52:54:00:CA:FE:EE,hostfwd=tcp::2222-:22,"$QEMU_NET_OPTS" \
	  -virtfs local,path=$(TMPDIR)/xchg,security_model=none,mount_tag=shared \
	  -virtfs local,path=$(TMPDIR)/xchg,security_model=none,mount_tag=xchg \
	  -blockdev driver=file,filename="$(disk_path)",node-name=file1 \
	  -blockdev driver=qcow2,file=file1,node-name=hd0 \
	  -device nvme,id=nvme0,serial=1234 \
	  -device nvme-ns,drive=hd0,nsid=1,bus=nvme0 \
	  -device virtio-keyboard \
	  -usb \
	  -device usb-tablet,bus=usb-bus.0 \
	  -serial unix:/tmp/$(vm_name).sock,server,nowait \
	  $$QEMU_OPTS

create_machines = $(shell for x in $$(echo "$(machines)" | sed 's/ /\n/'); do printf 'create_%s ' "$$x"; done)
create_%: vm_name=$*$(shell expr $(call vm_count,$*) + 1)
create_%: vm_dir=$(VMS_DIR)/$(vm_name)
## Create a new VM
$(create_machines): create_%: $(out_vm_dir)/run-%-vm $(out_vm_dir)/.run-%-vm.stamp $(secrets_qcow2)
	@echo -e "VM is \e[32m$(vm_name)\e[0m (at \e[32m$(vm_dir)\e[0m)"
	mkdir -p "$(vm_dir)"
	cp $(secrets_qcow2) "$(vm_dir)/secret-disk.qcow2"
	cp $(out_vm_dir)/run-$*-vm "$(vm_dir)/run-$*-vm"
	sed -i -e 's|QEMU_OPTS|QEMU_OPTS -drive file=$(vm_dir)/secret-disk.qcow2,id=drive2,if=none,index=2,werror=report -device virtio-blk-pci,drive=drive2 -serial unix:/tmp/$(vm_name).sock,server,nowait|' \
	  -e '3i export NIX_DISK_IMAGE="$(vm_dir)/$(vm_name).qcow2"' \
	  -e '3i export NIX_EFI_VARS="$(vm_dir)/$(vm_name)-efi-vars.fd"' \
	  "$(vm_dir)/run-$*-vm"

create_and_start_machines = $(shell for x in $$(echo "$(machines)" | sed 's/ /\n/'); do printf 'create_and_start_%s ' "$$x"; done)
## Create, starts and connect to a new VM
$(create_and_start_machines): create_and_start_%: create_% start_%

start_machines = $(shell for x in $$(echo "$(machines)" | sed 's/ /\n/'); do printf 'start_%s ' "$$x"; done)
start_%: vm_name=$*$(call vm_count,$*)
start_%: vm_dir=$(VMS_DIR)/$(vm_name)
## Start and connects the last existing VM
$(start_machines): start_%:
	@echo -e "VM is \e[32m$(vm_name)\e[0m (at \e[32m$(vm_dir)\e[0m)"
	if [ "$*" == "$(vm_name)" ]; then echo "No VMs found" && exit 1; fi
	if ps | grep [q]emu &>/dev/null; then echo "There is already a VM running" && exit 1; fi
	rm -f /tmp/$(vm_name).sock
	zellij run --name $(vm_name) --close-on-exit --floating -y0 -x80% --height=20% -- "$(vm_dir)/run-$*-vm"
	zellij action toggle-floating-panes
	$(MAKE) connect_$*

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
delete_old_vms_%: vm_numbers=$(shell find $(VMS_DIR) -type d -name '$(*)*' -printf '%f\n' | sed 's/$*//' | sort --general-numeric-sort)
## Delete old vms. It reads VM directories in the VMs dir and deletes all but the last one.
$(delete_old_vms_machines): delete_old_vms_%:
	if [ $$(echo "$(vm_numbers)" | wc -w) -lt 2 ]; then \
	  echo "No VMs to delete"; \
	else \
	  for vm_number in $$(echo "$(vm_numbers)" | sed 's/ /\n/g' | head -n-1); do \
	    vm=$$(printf '$*%s' "$$vm_number"); \
	    echo "Deleting VM: $$vm"; \
	    rm -rf "$(VMS_DIR)/$$vm"; \
	  done; \
	  printf "VMs left: "; \
	  find $(VMS_DIR) -type d -name '$(*)*' -printf '%f '; \
	fi;

### Tests
## Runs a quick boot test
test:
	nix build .#checks.$(architecture)-linux.boot-test --print-build-logs --no-link

### Information
## List machines
list_machines:
	@echo "Machines: $(machines)"

## List VMs
list_vms:
	@machines="$(machines)"; \
	machines="$${machines% }"; \
	echo -e "VMs created: \n""$$(find /mnt/data/vms -maxdepth 1 -type d -regex ".*/\($${machines// /\\|}\)[^/]*" -printf '%f\n' | sort --version-sort)"

## List outputs
list_outputs:
	@echo "VMs:" $(vm_files)
	@echo "ISOs:" $(iso_files)
	@echo "Imgs:" $(img_files)
	@echo "Systems:" $(machine_systems)
	@echo "Disks:" $(empty_qcow2) $(secrets_qcow2)

## Shows flake information
flake_show:
	nix flake show

### Others
## Default target (do not use)
default:
	@echo "no default target"
	exit 1
