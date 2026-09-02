#!/usr/bin/env bash
# Start the software TPM for a VM, idempotently.
#
# The VMs the Makefile generates from nixpkgs' qemu-vm.nix start swtpm themselves; this is for the from-ISO path,
# whose qemu command line is written by hand and therefore has to do it by hand too. It is copied into the VM
# directory at creation, the way the rest of that VM's launch machinery is, so a VM stays runnable without the
# repository.
#
# THE STATE DIRECTORY IS NOT SCRATCH. The TPM's seed lives in it, and the seed is what a key sealed to that TPM is
# bound to - deleting it is indistinguishable from swapping the motherboard, and every LUKS volume enrolled
# against it stops unlocking. It therefore lives beside the VM's disks and dies with them.
set -euo pipefail

# swtpm joined the devshell on 2026-09-02, so a shell entered before that does not have it and `set -e` would
# otherwise abort with nothing but "command not found".
if ! command -v swtpm >/dev/null; then
  echo "start-tpm.sh: swtpm is not on PATH. Re-enter the devshell (nix develop / direnv reload) - it was" >&2
  echo "              added to it on 2026-09-02 - or run this under: nix shell nixpkgs#swtpm -c ..." >&2
  exit 1
fi

dir="${1:?usage: start-tpm.sh <vm dir>}/swtpm"
mkdir -p "$dir"

# Already running: leave it alone. `make start_%` and the run script can both call this, and a second swtpm on the
# same state directory is a corrupted TPM rather than an error.
if [ -f "$dir/pid" ] && kill -0 "$(cat "$dir/pid")" 2>/dev/null; then
  exit 0
fi
rm -f "$dir/socket.ctrl" "$dir/pid"

# NO `--server`. qemu's `-tpmdev emulator` hands swtpm a file descriptor over the CONTROL socket, and swtpm
# refuses that when it was started with a data channel of its own: "tpm-emulator: Failed to send CMD_SET_DATAFD:
# Argument list too long". Observed 2026-08-30 with qemu 10.2.4 and swtpm 0.11.0. nixpkgs' own module passes
# --server and works, so something differs between the two paths; this is the form that was verified here.
swtpm socket \
  --tpmstate dir="$dir" \
  --ctrl type=unixio,path="$dir/socket.ctrl" \
  --pid file="$dir/pid" \
  --tpm2 --daemon \
  --log file="$dir/log",level=1
