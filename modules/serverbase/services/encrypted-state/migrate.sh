# Move application state into the container, once, per path.
#
#   encrypted-state-migrate --dry-run          what would move, and how much
#   encrypted-state-migrate                    move everything declared
#   encrypted-state-migrate /var/lib/mything   move one path
#   encrypted-state-migrate --cleanup          delete the .premigrated copies, once you trust the move
#
# The destructive half of the design. The shape is stop, copy, VERIFY, then swap - and the swap is a RENAME, not a
# delete, so a migration that went wrong is undone by renaming <path>.premigrated back. Where this sits in the
# deploy, and how long the services are down for it: docs/encrypted-state.md.

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
#
# Stopping a service is not enough to keep it stopped. Whatever triggers it - a .timer, a .path - is still armed,
# and on gmktec1's first real migration one fired mid-copy: mbsync ran against a directory rsync was reading, wrote
# `.mbsyncstate.lock`, and the verification correctly refused to move a copy that no longer matched. So the
# triggers go down first, and stay down: bringing them back here would re-arm them for the rest of the window, and
# the deploy that follows starts them anyway.
stop_units() {
  local unit trigger rc=0
  # shellcheck disable=SC2086
  for unit in $1; do
    if [ "$(systemctl show -p LoadState --value "$unit")" != "loaded" ]; then
      echo "  $unit is not loaded on this machine; nothing to stop"
      continue
    fi
    for trigger in $(systemctl show -p TriggeredBy --value "$unit"); do
      echo "  stopping $trigger, which would otherwise start $unit again mid-migration"
      systemctl stop "$trigger" || rc=1
    done
    # A stop that fails must not abort the run under `set -e`. It happened on gmktec1: stopping
    # docker-immich_server let its .path unit re-trigger it, the conflicting job cancelled the stop of
    # docker-immich_postgres, and the script died between two paths - leaving some data moved, some not, and the
    # empty directories of the moved ones exposed. The caller skips this path instead and carries on.
    systemctl stop "$unit" || rc=1
  done
  return "$rc"
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

# Nothing may start on the empty directory a moved path leaves behind. See the call site for what happened when
# nothing did.
#
# A drop-in, not `systemctl mask`, and both halves of that matter on NixOS:
#
#   - `mask --runtime` writes /run/systemd/system/<unit>, but /etc/systemd/system OUTRANKS /run for unit files and
#     NixOS puts every unit in /etc. The mask is created, systemd ignores it, and the guard silently does nothing.
#     (Persistent `mask --force` would work by replacing NixOS's own symlink, and unmasking would then leave the
#     unit with no definition at all until the next switch. Not a trade worth making.)
#   - DROP-INS are collected from every search path rather than shadowed by the winner, so one in /run does apply.
#
# ConditionPathIsMountPoint says exactly what is meant: not "never start" but "do not start until this path is
# really the container". It needs no undoing to become correct - the second deploy makes the condition true - it
# cannot be overridden by a service that runs as root, and a unit whose condition fails is skipped quietly rather
# than failed, which is the right noise level for a state the operator is deliberately in the middle of.
guard_units() {
  local unit dir
  # shellcheck disable=SC2086
  for unit in $2; do
    dir="/run/systemd/system/${unit}.d"
    mkdir -p "$dir"
    printf '[Unit]\nConditionPathIsMountPoint=%s\n' "$1" >"$dir/$GUARD_DROPIN"
  done
  if [ -n "$2" ]; then
    systemctl daemon-reload
    echo "  guarded until $1 is bound: ${2}"
  fi
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
    # A path an earlier run already moved. This is the normal shape of a resumed migration - the first real one on
    # gmktec1 was interrupted twice - so it is a SKIP, not a failure. Reporting it as a failure made a run in which
    # everything was correctly migrated end with "one or more paths did not migrate", which is the opposite of the
    # truth and exactly the wrong thing to read at that moment.
    if [ -d "$dest" ]; then
      echo "  already migrated by an earlier run; nothing to do."
    else
      echo "  FAIL: $path.premigrated exists but $dest does not - an earlier run stopped somewhere it should" >&2
      echo "  not have been able to. Resolve it by hand before going further." >&2
      failed=1
    fi
    continue
  fi

  size=$(du -sh "$path" | cut -f1)
  echo "  $size to copy, units: ${units:-none}"

  if [ "$dry_run" -eq 1 ]; then
    continue
  fi

  if [ -n "$units" ]; then
    echo "  stopping ${units}"
    if ! stop_units "$units"; then
      echo "  FAIL: could not stop everything that reads $path. Nothing has been moved." >&2
      echo "  Stop them by hand - a container target or a .path unit may be re-triggering one - and run again." >&2
      failed=1
      continue
    fi
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

  # From here until the second deploy, $path is an EMPTY directory that nothing is guarding. bindState is still
  # false, so there is no mount for RequiresMountsFor to hold a service back, and a service that starts now finds
  # no data where its data should be - which for a database means initdb, not an error.
  #
  # That is not hypothetical. On gmktec1's first migration something pulled postgresql.service during this window
  # and it built a brand new empty cluster on the root filesystem, seven minutes after its real one had been
  # copied into the container. Nothing was lost, because the real data was already in two places, but it is the
  # exact accident the whole design exists to prevent, arriving through the one gap where the guards do not apply.
  #
  # In /run, so an interrupted migration cannot leave a machine permanently crippled: a reboot clears the guards,
  # and a reboot with the data already in the container is a machine one `nixos-rebuild switch` away from correct.
  guard_units "$path" "$units"

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
