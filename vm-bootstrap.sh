#!/usr/bin/env bash
# Runs INSIDE a VM, delivered by `make bootstrap_<machine>` over ssh. Not packaged into any system.
#
# A VM is created from nothing, so anything that keeps its state in an encrypted container has nowhere to put it
# until that container exists - and nothing creates one at boot, deliberately, because `encrypted-state-init`
# generates a recovery passphrase and that is not something to do unattended. This runs the manual half.
set -euo pipefail

if ! command -v encrypted-state-status >/dev/null 2>&1; then
  echo "  no encrypted state container on this machine; nothing to bootstrap."
  exit 0
fi

# `encrypted-state-status` exits non-zero whenever state is not coming from the container, which is the normal
# condition BOTH before this runs and after it - a VM has bindState false, so the paths are never bound. So its
# output is read and its exit code deliberately ignored.
if encrypted-state-status 2>/dev/null | grep -q "MISSING, never created"; then
  echo "  creating the container..."
  sudo encrypted-state-init
  echo "  migrating state into it..."
  sudo encrypted-state-migrate
else
  echo "  container already exists; leaving it alone."
fi

echo
status="$(encrypted-state-status 2>&1 || true)"
printf '%s\n' "$status"

# What is left to do depends on whether the paths are bound, so ask rather than assume - printing "now flip
# bindState" at a VM that is already bound is how a runbook teaches people to ignore it.
if printf '%s' "$status" | grep -q DEGRADED; then
  cat <<'BANNER'

===========================================================================
  The container exists and holds the state, but it is NOT bound - which is
  what DEGRADED above means. Binding it is the last step, and it needs an
  editor:

      set bindState = true in this machine's encrypted_state.nix
      sudo nixos-rebuild switch --flake ~/.config/nixos

  Keep that edit inside the VM. The committed value is deliberately false
  for VMs, so that a fresh one can be created at all.
===========================================================================
BANNER
else
  echo
  echo "The container is bound and serving every declared path. Nothing left to do."
fi
