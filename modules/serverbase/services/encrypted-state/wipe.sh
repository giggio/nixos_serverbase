# Initialise a container's integrity tags, in chunks, recording where it got to.
#
# WHY THIS EXISTS AT ALL. `cryptsetup luksFormat --integrity` wipes the whole device itself before it returns, and
# that is the correct thing for it to do - every sector has to carry a tag before anything reads it. What it does
# not do is keep any record of how far it got, so the operation is all-or-nothing. On a 4 TiB container on the
# opi4pronas array that is a 48 hour window in which any interruption costs all 48 hours. It was interrupted twice:
# by this module's own retry timer on 2026-08-20, and by a house power cut on 2026-08-22.
#
# So the format is run with `--integrity-no-wipe` and the wipe happens here instead, one chunk at a time, with the
# offset written to persistent storage after each. An interruption now costs one chunk.
#
# The ordering that makes this safe is in init.sh, and it is worth stating here too: the clevis binding is made
# BEFORE the wipe starts. A power cut during the format used to leave a container nothing could open, because the
# bind had not happened yet; now it leaves a container that opens normally and has some wiping left to do.

if [ -z "$INTEGRITY" ]; then
  echo "FATAL: this container has no integrity protection, so it has no tags to initialise." >&2
  echo "encrypted-state-wipe is only for containers created with setup.encryptedState.integrity set." >&2
  exit 1
fi

if [ ! -e "$IMAGE" ]; then
  echo "FATAL: $IMAGE does not exist; there is nothing to wipe." >&2
  exit 1
fi

uuid=$(cryptsetup luksUUID "$IMAGE")

# The progress file is keyed to the container it describes. Without this, a stale file left behind by a container
# that was deleted and recreated would be read as progress against the new one - and the new one would then skip
# straight past however many terabytes the OLD one had managed, leaving a container whose tags are uninitialised in
# a region nothing will ever check again. That is the one failure this design could introduce that the all-or-
# nothing version could not, so it is guarded before anything else is read.
read_progress() {
  progress_uuid=""
  progress_size=""
  progress_offset=""
  [ -e "$WIPE_PROGRESS" ] || return 1
  # shellcheck disable=SC1090
  . "$WIPE_PROGRESS"
  progress_uuid="${wipe_uuid:-}"
  progress_size="${wipe_size:-}"
  progress_offset="${wipe_offset:-}"
  [ -n "$progress_uuid" ] && [ -n "$progress_size" ] && [ -n "$progress_offset" ]
}

write_progress() { # $1 = offset in bytes
  # Written through a temporary file and renamed, so a reader never sees a half-written record and a crash in the
  # middle of the write cannot leave a file that parses but lies. `sync` on the directory afterwards is what makes
  # the rename itself durable, which is the property the whole design rests on.
  tmp="${WIPE_PROGRESS}.new"
  {
    echo "# Written by encrypted-state-wipe. Where the integrity wipe of $IMAGE has got to."
    echo "# While wipe_offset < wipe_size the container is NOT usable: reading past the offset is an"
    echo "# integrity failure by construction. encrypted-state-unlock refuses to open it until this is done."
    echo "wipe_uuid=$uuid"
    echo "wipe_size=$total"
    echo "wipe_offset=$1"
  } >"$tmp"
  sync "$tmp"
  mv -f "$tmp" "$WIPE_PROGRESS"
  sync "$(dirname "$WIPE_PROGRESS")"
}

# The stale-record check comes BEFORE anything is opened, because it is the one error here that means "do not touch
# this container at all" - and because the UUID can be read straight off the file.
have_progress=0
if read_progress; then
  have_progress=1
  if [ "$progress_uuid" != "$uuid" ]; then
    echo "FATAL: $WIPE_PROGRESS describes a DIFFERENT container." >&2
    echo "  it records LUKS UUID $progress_uuid" >&2
    echo "  $IMAGE has        LUKS UUID $uuid" >&2
    echo "A stale record from a container that was deleted and recreated. Resuming against it would skip a region" >&2
    echo "of this container whose tags are uninitialised, and nothing would ever check it again." >&2
    echo "Delete $WIPE_PROGRESS to wipe this container from the beginning." >&2
    exit 1
  fi
fi

# A name of its own rather than $MAPPER. The mount unit and everything ordered after it key off /dev/mapper/$MAPPER,
# and a half-wiped container appearing under that name is an invitation for something to mount it.
wipe_mapper="${MAPPER}-wiping"

# What the previous run left behind, if it was killed rather than stopped. A reboot clears device-mapper and loop
# devices, so the power-cut case arrives clean - but a SIGKILL does not run the trap below, and then this device is
# still here on the next attempt. Tearing it down rather than reusing it: its state is unknown, and the exclusive
# lock this script holds means nothing else can be using it.
if [ -e "/dev/mapper/$wipe_mapper" ]; then
  echo "removing $wipe_mapper left behind by an interrupted wipe"
  cryptsetup close "$wipe_mapper" || {
    echo "FATAL: /dev/mapper/$wipe_mapper exists and will not close." >&2
    echo "Something is still using it. Find it with: lsof /dev/mapper/$wipe_mapper" >&2
    exit 1
  }
fi

attached_here=0
cleanup() {
  cryptsetup close "$wipe_mapper" 2>/dev/null || true
  # Only what this invocation attached - the same rule, and for the same reason, as encrypted-state-unlock.
  [ "$attached_here" = "1" ] && [ -n "${loop:-}" ] && losetup --detach "$loop" 2>/dev/null
  return 0
}
trap cleanup EXIT

# Reuse a loop device already attached to this file rather than adding a second one. Two loop devices over the same
# image are two independent views of the same bytes, and writing through both is how it gets corrupted. An
# interrupted wipe leaves exactly that behind.
loop=$(losetup --associated "$IMAGE" --noheadings --output NAME | head -n1)
if [ -n "$loop" ]; then
  echo "reusing existing loop device $loop for $IMAGE"
else
  loop=$(losetup --find --show --direct-io=on "$IMAGE" 2>/dev/null) ||
    loop=$(losetup --find --show "$IMAGE")
  attached_here=1
fi

# Opened against the key server, not against a passphrase, and that is what makes an unattended resume possible: a
# machine that reboots mid-wipe picks up where it left off with nobody at the keyboard.
if ! clevis luks unlock -d "$loop" -n "$wipe_mapper" \
  -o "--perf-no_read_workqueue --perf-no_write_workqueue"; then
  echo "FATAL: could not open $IMAGE against the key server to wipe it." >&2
  echo "The container is sound; only this could not start. Fix the key server, then run encrypted-state-wipe." >&2
  exit 1
fi

dev="/dev/mapper/$wipe_mapper"
total=$(blockdev --getsize64 "$dev")
chunk="$WIPE_CHUNK_BYTES"

start=0
if [ "$have_progress" -eq 1 ]; then
  if [ "$progress_size" != "$total" ]; then
    echo "FATAL: $WIPE_PROGRESS records a size of $progress_size bytes; $dev is $total bytes." >&2
    echo "Refusing to resume against a record that does not describe this device." >&2
    exit 1
  fi
  if [ "$progress_offset" -ge "$total" ]; then
    echo "The wipe of $IMAGE is already complete ($(numfmt --to=iec "$total"))."
    exit 0
  fi
  # Back off one chunk. `conv=fsync` below means the recorded offset is genuinely on stable storage, so this is not
  # strictly needed - but dm-integrity commits through a journal, and a power cut takes the tail of that journal
  # with it. Redoing 64 MiB costs seconds and removes the whole question.
  start=$((progress_offset > chunk ? progress_offset - chunk : 0))
  echo "Resuming the wipe of $IMAGE at $(numfmt --to=iec "$start") of $(numfmt --to=iec "$total")" \
    "($(awk -v a="$start" -v b="$total" 'BEGIN{printf "%.2f", a*100/b}')% done)."
else
  echo "Starting the wipe of $IMAGE: $(numfmt --to=iec "$total") to initialise."
  echo "This is the long part. It is resumable - if it is interrupted, run encrypted-state-wipe again."
fi

began=$(date +%s)
began_at="$start"
offset="$start"
last_report=0

while [ "$offset" -lt "$total" ]; do
  remaining=$((total - offset))
  this=$((remaining < chunk ? remaining : chunk))

  # oflag=direct so 4 TiB of zeroes does not evict every useful page on a box with 3.8 GiB of RAM and no swap.
  # conv=fsync so that when dd returns, the chunk is on the disk and not merely in dm-integrity's journal - which
  # is what lets the offset be recorded as fact rather than as hope.
  if ! dd if=/dev/zero of="$dev" bs="$this" count=1 seek="$offset" \
    oflag=direct,seek_bytes conv=fsync status=none; then
    echo >&2
    echo "FATAL: writing at offset $offset failed." >&2
    echo "Progress up to $(numfmt --to=iec "$offset") is recorded; run encrypted-state-wipe to resume." >&2
    exit 1
  fi

  offset=$((offset + this))
  write_progress "$offset"

  now=$(date +%s)
  if [ $((now - last_report)) -ge 300 ] || [ "$offset" -ge "$total" ]; then
    last_report=$now
    elapsed=$((now - began))
    if [ "$elapsed" -gt 0 ]; then
      rate=$(((offset - began_at) / elapsed))
      # Deliberately reported as an average since this run started rather than as an instantaneous rate. A spot
      # rate on this hardware is not an ETA: the wipe walks toward the inner tracks of the platter and slows as it
      # goes, and a 60-second sample taken at 91% once predicted three hours for work that had not finished ten
      # hours later.
      eta="unknown"
      [ "$rate" -gt 0 ] && eta="$(((total - offset) / rate / 60)) min at the average rate so far"
      echo "  wiped $(numfmt --to=iec "$offset") of $(numfmt --to=iec "$total")" \
        "($(awk -v a="$offset" -v b="$total" 'BEGIN{printf "%.2f", a*100/b}')%)," \
        "$(numfmt --to=iec "$rate")/s average, $eta remaining"
    fi
  fi
done

echo "The wipe of $IMAGE is complete: every sector of $(numfmt --to=iec "$total") now carries a valid tag."
