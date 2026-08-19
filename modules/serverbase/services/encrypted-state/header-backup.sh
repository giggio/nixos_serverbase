# Copy the container's LUKS2 header out, because it is the one part of this design whose loss is total.
#
# Everything else about a LUKS container degrades the way plain storage does. `aes-xts-plain64` derives its tweak
# from the sector number and chains nothing, so a damaged sector damages that sector and no other, and the file that
# owns it is the only file lost - exactly as on the filesystem underneath. The header is the exception. It is 16 MiB
# at the front holding the keyslots, and the keyslots hold the master key. Lose those bytes and every byte of data
# behind them is gone: not degraded, not partially readable, gone, because the key that decrypts them was in there.
# LUKS2 keeps a second copy of the *binary* header for this reason, and cryptsetup falls back to it automatically -
# but the keyslot area is NOT duplicated, so that fallback does not cover the case that matters.
#
# The header also carries the clevis JWE, in a LUKS2 token. So this file is what lets a restored container still
# unlock against the key server, rather than only against the recovery passphrase.
#
# THIS FILE IS KEY MATERIAL. It is not a copy of the data and cannot be decrypted by itself, but it holds the same
# keyslots the container does: whoever has it plus either the recovery passphrase or reach to the key server opens
# the volume. And it holds them as they were WHEN IT WAS TAKEN - restoring a stale backup revives a keyslot that was
# killed since. Treat it like the passphrase.

check_only=0
export_to=""
dest=""
while [ "$#" -gt 0 ]; do
  case "$1" in
  --check) check_only=1 ;;
  # The copy that leaves the machine. Encrypted here rather than on a workstation because there is no good way to
  # get 16 MiB of root-owned key material off a server that asks for a sudo password: `ssh host sudo cat` cannot
  # authenticate, and `ssh -t` puts the terminal in cooked mode and corrupts the binary stream. The alternative is
  # copying the plaintext to /tmp, scp-ing it and remembering to delete it, which is three chances to leave key
  # material lying around. The recipients come from the configuration, so there is nothing to retype in two years.
  --export)
    shift
    [ "$#" -gt 0 ] || {
      echo "--export needs a path to write to" >&2
      exit 1
    }
    export_to="$1"
    ;;
  -*)
    echo "usage: encrypted-state-header-backup [--check] [--export <file.age>] [destination]" >&2
    exit 1
    ;;
  *) dest="$1" ;;
  esac
  shift
done
dest="${dest:-$HEADER_BACKUP}"

if [ -n "$export_to" ] && [ -z "$HEADER_EXPORT_RECIPIENTS" ]; then
  echo "FATAL: --export needs setup.encryptedState.headerExportRecipients to be set." >&2
  echo "Without a recipient the only thing this could write is the plaintext header, which is the one thing" >&2
  echo "that must not be copied around." >&2
  exit 1
fi

if [ ! -e "$IMAGE" ]; then
  echo "FATAL: $IMAGE does not exist, so there is no header to back up. Run encrypted-state-init." >&2
  exit 1
fi

if ! cryptsetup isLuks --type luks2 "$IMAGE"; then
  echo "FATAL: $IMAGE is not a LUKS2 container." >&2
  exit 1
fi

# `cryptsetup luksHeaderBackup` writes exactly the bytes from 0 to the data offset - verified, byte for byte - so
# the backup is current precisely when it equals the front of the container. That makes the check a read of 16 MiB
# and no write at all, which is what lets encrypted-state-status ask the same question on every invocation.
#
# It is also exact rather than approximate: every write to a LUKS2 header bumps the seqid in the binary header at
# byte 24, so an added keyslot, a killed one, a changed passphrase and a clevis re-bind all show up here.
header_matches() {
  local size
  [ -e "$dest" ] || return 1
  size=$(stat -c %s "$dest")
  [ "$size" -gt 0 ] || return 1
  cmp -s -n "$size" "$dest" "$IMAGE"
}

if [ "$check_only" -eq 1 ]; then
  if [ ! -e "$dest" ]; then
    echo "MISSING: no header backup at $dest."
    echo "Take one with encrypted-state-header-backup, then copy it off this machine."
    exit 1
  fi
  if header_matches; then
    echo "current: $dest matches the container's header."
    exit 0
  fi
  echo "STALE: $dest no longer matches the header in $IMAGE."
  echo "Something has changed the keyslots or tokens since it was taken. Restoring it now would put the OLD set"
  echo "back - reviving a keyslot that was killed, and dropping one that was added. Re-take it, and replace the"
  echo "copy that lives off this machine; a stale copy in two places is worse than one."
  exit 1
fi

# age, not gpg: the recipients are the same age keys .sops.yaml already uses for this machine, so the copy that
# leaves here opens with keys that already exist and are already looked after. Encrypted to more than one, because
# the two situations that call for it are different - a header damaged on a healthy machine, and a machine that no
# longer exists - and they are not reachable with the same key.
export_backup() {
  local recipient host args=()
  [ -n "$export_to" ] || return 0
  for recipient in $HEADER_EXPORT_RECIPIENTS; do
    args+=(--recipient "$recipient")
  done
  age "${args[@]}" -o "$export_to" "$dest"
  # 0644 on purpose: it is ciphertext now, and the next step is copying it off with an ordinary unprivileged scp.
  chmod 0644 "$export_to"
  echo
  echo "  Encrypted copy written to $export_to"
  echo "  Recipients: $HEADER_EXPORT_RECIPIENTS"
  echo
  echo "  Copy it off the machine and DELETE IT HERE - a copy that stays is not an off-machine copy:"
  echo
  # `uname -n` rather than `hostname`: coreutils is in this script's runtimeInputs and hostname is not, so the
  # latter works only because writeShellApplication keeps the caller's PATH - which a systemd unit may not have.
  host=$(uname -n)
  echo "      scp $host:$export_to ."
  echo "      ssh $host rm -f $export_to"
  echo
  echo "  Where the copies go, and how many there should be, is in the configuration repository's"
  echo "  docs/encrypted-state.md."
}

if header_matches; then
  echo "unchanged: $dest already matches the container's header. Nothing written."
  export_backup
  exit 0
fi

mkdir -p "$(dirname "$dest")"

# Written beside the destination rather than in /run, so replacing it is a rename within one filesystem and a
# failure half way through cannot leave a truncated backup where a good one was.
tmp="${dest}.new"
rm -f "$tmp" # cryptsetup refuses to write to a file that exists, which a previous failed run may have left
trap 'rm -f "$tmp"' EXIT

cryptsetup luksHeaderBackup "$IMAGE" --header-backup-file "$tmp"

# A header backup file is itself a valid LUKS device as far as cryptsetup is concerned, so this reads back what was
# just written and proves it is a header rather than a short write. Done BEFORE the old one is replaced: the moment
# to discover a bad copy is while the good copy is still there.
if [ "$(cryptsetup luksUUID "$tmp" 2>/dev/null)" != "$(cryptsetup luksUUID "$IMAGE")" ]; then
  echo "FATAL: the copy at $tmp does not read back as this container's header. $dest left alone." >&2
  exit 1
fi

replaced=0
[ -e "$dest" ] && replaced=1
mv -f "$tmp" "$dest"
trap - EXIT
chmod 0400 "$dest"

slots=$(cryptsetup luksDump "$dest" | grep -cE '^  [0-9]+: luks2' || true)
tokens=$(cryptsetup luksDump "$dest" | grep -c 'clevis' || true)

echo
echo "==========================================================================="
if [ "$replaced" -eq 1 ]; then
  echo "  Header backup REFRESHED at $dest"
  echo "  The previous one is gone; it described a different set of keyslots."
else
  echo "  Header backup written to $dest"
fi
echo "  $(stat -c %s "$dest") bytes, keyslots: $slots, clevis tokens: $tokens"
echo "==========================================================================="
echo
echo "  This is KEY MATERIAL, not a copy of your data. Anyone holding it and either the"
echo "  recovery passphrase or reach to the key server can open the container."
echo
echo "  Copy it somewhere the loss of this machine's disk does not reach, and keep it"
echo "  with the recovery passphrase rather than next to the container."
echo
echo "  Re-take it after ANYTHING that changes a keyslot: luksAddKey, luksKillSlot,"
echo "  luksChangeKey, clevis luks bind or unbind. encrypted-state-status says when it"
echo "  has gone stale, and encrypted-state-header-backup --check is the same question."
echo
echo "  To put it back, after reading docs/encrypted-state.md - this direction is the"
echo "  dangerous one, and it overwrites the live keyslots:"
echo
echo "      cryptsetup luksHeaderRestore $IMAGE --header-backup-file $dest"
echo

export_backup
