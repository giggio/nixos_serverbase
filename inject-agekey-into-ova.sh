#!/usr/bin/env bash

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

if ! [ -v 1 ]; then
  OVA_IN="$(find result/ -name '*.ova')"
else
  OVA_IN="$1"
fi
if ! [ -v 2 ]; then
  DEST_DIR="$DIR/result"
else
  DEST_DIR="$(realpath "$2")"
fi
AGEKEY="${3:-$HOME/.config/nixos-secrets/server.agekey}"

if [ "$(echo "$OVA_IN" | wc -l)" -gt 1 ]; then
  echo "Multiple OVA files found: $OVA_IN" >&2
  exit 1
fi

if [ ! -f "$OVA_IN" ]; then
  echo "OVA not found: $OVA_IN" >&2
  exit 1
fi

echo "Using OVA: $OVA_IN"

if [ ! -f "$AGEKEY" ]; then
  echo "age key not found: $AGEKEY" >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "Working directory: $WORKDIR"

# 1. Unpack the OVA
echo "Extracting OVA..."
tar -xf "$OVA_IN" -C "$WORKDIR"

OVF="$(ls "$WORKDIR"/*.ovf)"
echo "Using OVF: $OVF"

# 2. Create extra disk
EXTRA_RAW="$WORKDIR/secret-disk.raw"
EXTRA_VMDK="$WORKDIR/secret-disk.vmdk"

echo "Creating extra disk $EXTRA_RAW..."
qemu-img create -f raw "$EXTRA_RAW" 4M
virt-format -a "$EXTRA_RAW" --filesystem=ext4

# 3. Copy the key into the disk
echo "Injecting server.agekey..."
# virt-copy-in -a "$EXTRA_RAW" "$AGEKEY" /nixos-secrets
sudo guestfish -a "$EXTRA_RAW" <<'EOF'
run
# optional: show discovered filesystems for debug
# list-filesystems
# explicit mount (adjust device name as reported by list-filesystems)
mount /dev/sda1 /
mkdir-p /nixos-secrets
upload /home/giggio/.config/nixos-secrets/server.agekey /nixos-secrets/server.agekey
chmod 0400 /nixos-secrets/server.agekey
sync
exit
EOF

# 4. Convert to VMDK
echo "Converting to VMDK file $EXTRA_VMDK..."
qemu-img convert -f raw -O vmdk "$EXTRA_RAW" "$EXTRA_VMDK"

# 5. Patch the OVF to reference the new disk
echo "Patching OVF..."

DISK_ID="disk-secret"
FILE_ID="file-secret"
DISK_UUID=$(uuidgen)

echo "Patching $OVF..."
sed -i \
  -e "/<References>/a\
    <File ovf:id=\"$FILE_ID\" ovf:href=\"$(basename "$EXTRA_VMDK")\" />" \
  "$OVF"

sed -i \
  -e "/<\/DiskSection>/i\
    <Disk ovf:diskId=\"$DISK_ID\" ovf:fileRef=\"$FILE_ID\" ovf:capacity=\"$(stat -c%s "$EXTRA_VMDK")\" ovf:format=\"http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized\" vbox:uuid=\"$DISK_UUID\" />" \
  "$OVF"

PARENT_ID="$(yq -oyaml -p xml '(.Envelope.VirtualSystem.VirtualHardwareSection.Item | first(.["rasd:ResourceType"] == "17"))["rasd:Parent"]' "$OVF")"
if [ -z "$PARENT_ID" ]; then
  echo "Could not find disk parent ID in $OVF" >&2
  exit 1
fi
echo "Found disk parent ID: $PARENT_ID"
sed -i \
  -e "/<\/VirtualHardwareSection>/i\
    <Item>\
      <rasd:AddressOnParent>1</rasd:AddressOnParent>\
      <rasd:Caption>Secret Disk</rasd:Caption>\
      <rasd:Description>Secret Disk</rasd:Description>\
      <rasd:ElementName>disk2</rasd:ElementName>\
      <rasd:InstanceID>99</rasd:InstanceID>\
      <rasd:ResourceType>17</rasd:ResourceType>\
      <rasd:Parent>$PARENT_ID</rasd:Parent>\
      <rasd:HostResource>ovf:/disk/$DISK_ID</rasd:HostResource>\
    </Item>" \
  "$OVF"

sed -i "/<\/StorageController>/i\\
          <AttachedDevice type=\"HardDisk\" hotpluggable=\"false\" port=\"1\" device=\"0\">\\
            <Image uuid=\"{${DISK_UUID}}\" />\\
          </AttachedDevice>" \
  "$OVF"

cd "$WORKDIR"
MF_FILE="$(find . -maxdepth 1 -type f -name '*.mf' -printf '%f')"
echo "Recreating manifest file $MF_FILE..."
rm "$MF_FILE"
for file in *.{vmdk,ovf}; do
  sha1=$(sha1sum "$file" | awk '{print $1}')
  echo "SHA1 ($file) = $sha1" >>"$MF_FILE"
done

# 6. Repack the OVA
OVA_OUT="${OVA_IN%.ova}-with-agekey.ova"
if [ -L "$DEST_DIR" ]; then
  # remove if the destination is a symlink
  rm -rf "$DEST_DIR"
fi
mkdir -p "$DEST_DIR"
OVA_OUT="$DEST_DIR/${OVA_OUT##*/}"

echo "Removing raw file $EXTRA_RAW..."
rm "$EXTRA_RAW"

echo "Contents of $WORKDIR:"
ls -lA "$WORKDIR"

echo "Repacking OVA -> $OVA_OUT"
find . -maxdepth 1 -type f -printf '%f\0' |
  tar --null --format=ustar --numeric-owner --owner=0 --group=0 -cvf "$OVA_OUT" --no-recursion --files-from=-

echo "Done."
