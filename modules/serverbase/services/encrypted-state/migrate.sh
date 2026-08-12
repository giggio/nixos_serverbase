# Move application state into the container, once, per path.
#
#   encrypted-state-migrate --dry-run          what would move, and how much
#   encrypted-state-migrate                    move everything declared
#   encrypted-state-migrate /var/lib/mything   move one path
#   encrypted-state-migrate --cleanup          delete the .premigrated copies, once you trust the move
#
# This is the destructive half of the design, so the shape is: stop, copy, VERIFY, then swap - and the swap is a
# rename, not a delete. The original stays on disk as <path>.premigrated until an explicit --cleanup, which means a
# migration that went wrong is undone by renaming it back rather than by restoring a backup.
#
# Services are down from the moment this starts until the switch that follows it. That is the maintenance window,
# and it is as long as the copy takes. Copying live and syncing the delta afterwards would shorten it, at the price
# of a second pass whose correctness depends on the service not having rewritten the world underneath it - not a
# trade worth making for a few gigabytes of database.

dry_run=0
cleanup=0
selected=()

for arg in "$@"; do
  case "$arg" in
  --dry-run) dry_run=1 ;;
  --cleanup) cleanup=1 ;;
  -*)
    echo "unknown option: $arg" >&2
    exit 2
    ;;
  *) selected+=("$arg") ;;
  esac
done

if ! grep -qF " $MOUNT_POINT " /proc/self/mounts; then
  echo "FATAL: the container is not mounted at $MOUNT_POINT." >&2
  echo "Start encrypted-state.target, or run encrypted-state-init if it has never been created." >&2
  exit 1
fi

# Each line is a path, a tab, then the units that read it.
mapfile -t spec_lines < <(printf '%s\n' "$STATE_SPEC" | grep -v '^[[:space:]]*$')

wanted() {
  [ ${#selected[@]} -eq 0 ] && return 0
  local candidate
  for candidate in "${selected[@]}"; do
    [ "$candidate" = "$1" ] && return 0
  done
  return 1
}

# The unit lists arrive as one space-separated string per path and are meant to word-split - the very thing the
# linter objects to everywhere else. Confining the split to these two helpers keeps the suppression in one place
# instead of scattering it over the loop below.
#
# Each unit is checked for LoadState before being touched, because `systemctl stop` on a unit systemd has no
# definition for exits 5, and under `set -e` that aborts the migration between stopping a service and copying its
# data - the worst possible moment. Not every unit named in the configuration is loaded on every machine: one may
# be masked, or belong to a service that has never been enabled here. Skipping those is correct; swallowing a
# genuine failure to stop a RUNNING service would not be, so this stays narrow rather than becoming `|| true`.
stop_units() {
  local unit
  # shellcheck disable=SC2086
  for unit in $1; do
    if [ "$(systemctl show -p LoadState --value "$unit")" = "loaded" ]; then
      systemctl stop "$unit"
    else
      echo "  $unit is not loaded on this machine; nothing to stop"
    fi
  done
}

start_units() {
  local unit
  # shellcheck disable=SC2086
  for unit in $1; do
    if [ "$(systemctl show -p LoadState --value "$unit")" = "loaded" ]; then
      systemctl start "$unit"
    fi
  done
}

if [ "$cleanup" -eq 1 ]; then
  for line in "${spec_lines[@]}"; do
    path="${line%%$'\t'*}"
    wanted "$path" || continue
    [ -d "$path.premigrated" ] || continue
    # Refuse while the bind is not in place: the .premigrated copy is the only copy until the container is actually
    # carrying the load, and "I ran cleanup before the second switch" must not be a way to lose a database.
    if ! grep -qF " $path " /proc/self/mounts; then
      echo "SKIP $path.premigrated - $path is not a bind mount yet, so this is still the live copy." >&2
      continue
    fi
    echo "removing $path.premigrated ($(du -sh "$path.premigrated" | cut -f1))"
    [ "$dry_run" -eq 1 ] || rm -rf "$path.premigrated"
  done
  exit 0
fi

failed=0
for line in "${spec_lines[@]}"; do
  path="${line%%$'\t'*}"
  units="${line#*$'\t'}"
  wanted "$path" || continue

  dest="${MOUNT_POINT}${path}"

  echo
  echo "=== $path -> $dest"

  if grep -qF " $path " /proc/self/mounts; then
    echo "  already a mount point; nothing to migrate."
    continue
  fi

  if [ ! -d "$path" ]; then
    echo "  $path does not exist on this machine; creating it empty inside the container."
    [ "$dry_run" -eq 1 ] || mkdir -p "$dest"
    continue
  fi

  if [ -e "$path.premigrated" ]; then
    echo "  FAIL: $path.premigrated already exists - a previous run got this far. Resolve it by hand." >&2
    failed=1
    continue
  fi

  size=$(du -sh "$path" | cut -f1)
  echo "  $size to copy, units: ${units:-none}"

  if [ "$dry_run" -eq 1 ]; then
    continue
  fi

  if [ -n "$units" ]; then
    echo "  stopping ${units}"
    stop_units "$units"
  fi

  mkdir -p "$dest"
  # -H hardlinks, -A ACLs, -X xattrs, --numeric-ids: everything that matters for state directories, and all four are
  # things whose absence would not show up until much later. Plenty of services rely on a group ACL on their data
  # directory, and systemd's own state carries xattrs.
  echo "  copying..."
  rsync -aHAX --numeric-ids --delete "$path/" "$dest/"

  # The verification is a second rsync in dry-run itemize mode: anything it would still change is something the
  # first pass got wrong. Comparing `du` totals would pass on two directories with the same size and different
  # contents, which is not a check.
  echo "  verifying..."
  diff_out=$(rsync -aHAXn --numeric-ids --delete --itemize-changes "$path/" "$dest/")
  if [ -n "$diff_out" ]; then
    echo "  FAIL: the copy does not match the original. Nothing has been moved; the original is untouched." >&2
    echo "$diff_out" | head -20 >&2
    failed=1
    start_units "$units"
    continue
  fi

  # The mountpoint keeps the original's ownership and mode. systemd would fix up anything with a StateDirectory=,
  # but not every path here has one, and a mountpoint with the wrong mode is visible for as long as the container is
  # locked - which is exactly when nobody wants a second puzzle.
  mv "$path" "$path.premigrated"
  mkdir "$path"
  chown --reference="$path.premigrated" "$path"
  chmod --reference="$path.premigrated" "$path"

  echo "  moved. original kept at $path.premigrated"
done

echo
if [ "$failed" -ne 0 ]; then
  echo "One or more paths did not migrate. Fix those before switching." >&2
  exit 1
fi

if [ "$dry_run" -eq 1 ]; then
  echo "Dry run only; nothing changed."
  exit 0
fi

echo "==========================================================================="
echo "  Data is in the container and the originals are parked at *.premigrated."
echo "  The services are DOWN until the configuration catches up. Now:"
echo "    1. set setup.encryptedState.bindState = true"
echo "    2. nixos-rebuild switch"
echo "    3. check the services, then encrypted-state-migrate --cleanup"
echo "==========================================================================="
