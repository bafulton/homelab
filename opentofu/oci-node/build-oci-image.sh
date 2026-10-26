#!/usr/bin/env bash
# Build & import the OCI custom boot image for the `ocifree` Talos node.
#
# Idempotent: the image is named for the Talos version (talos-<version>-arm64)
# and tagged with the extension schematic, so it rebuilds when EITHER the Talos
# version (talos/cluster.yaml) OR the extension set below changes. Safe to run any time.
#
# WHEN TO RUN
#   - Before the first `tofu apply` of opentofu/oci-node/.
#   - After a Talos version bump or an extension change here, so a future
#     *reprovision* boots a current image.
#   Routine in-place upgrades (tuppr via the installer image) do NOT need this -
#   the OCI custom image is only used at first boot / reprovision.
#
# The extension set below MUST match ocifree's `schematic` in talos/cluster.yaml
# (installed as factory.talos.dev/installer/<schematic>:<version>).
#
# Requires: oci CLI (reads ~/.oci/config), yq, curl, python3, qemu-img
# (brew install qemu - for the qcow2 -> VMDK conversion). No OCIDs in git.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER_FILE="$REPO_ROOT/talos/cluster.yaml"
BUCKET="talos-images"       # reused object-storage bucket
PLATFORM="oracle"
ARCH="arm64"
SHAPE="VM.Standard.A1.Flex" # must match opentofu instance_shape

# Image contents. Keep in sync with ocifree's schematic in talos/cluster.yaml.
# iscsi-tools is included so pods on ocifree can mount Longhorn PVCs: open-iscsi
# is required on ANY node that attaches a Longhorn volume (RWO volumes attach
# over iSCSI from the workload's node), not just storage nodes.
read -r -d '' SCHEMATIC_YAML <<'YAML' || true
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/iscsi-tools
      - siderolabs/tailscale
      - siderolabs/util-linux-tools
YAML

command -v yq >/dev/null || { echo "yq not found" >&2; exit 1; }
command -v qemu-img >/dev/null || { echo "qemu-img not found (brew install qemu)" >&2; exit 1; }
VERSION="$(yq -r '.talosVersion' "$CLUSTER_FILE")"            # e.g. v1.14.4
IMG_NAME="talos-${VERSION}-${ARCH}"                          # talos-v1.14.4-arm64
COMPARTMENT="$(awk -F= '/^tenancy=/{print $2}' "$HOME/.oci/config")"  # root compartment
REGION="$(awk -F= '/^region=/{print $2}' "$HOME/.oci/config")"
[ -n "$COMPARTMENT" ] || { echo "no tenancy= in ~/.oci/config" >&2; exit 1; }
[ -n "$REGION" ]      || { echo "no region= in ~/.oci/config" >&2; exit 1; }
IAAS="https://iaas.${REGION}.oraclecloud.com"

echo "Talos version (cluster.yaml): $VERSION"
echo "Target image:              $IMG_NAME"

# Custom image imports default to a legacy amd64 shape list that omits the
# Ampere A1 Flex shape ocifree uses, so LaunchInstance fails with "Shape ... is
# not valid for image". Add the entry (idempotent; a duplicate add is a no-op).
ensure_shape_compat() {
  local img_id="$1"
  if oci compute image-shape-compatibility-entry list --image-id "$img_id" 2>/dev/null \
    | python3 -c 'import sys,json;d=json.load(sys.stdin).get("data",[]);sys.exit(0 if any(e["shape"]=="'"$SHAPE"'" for e in d) else 1)'; then
    echo "Shape $SHAPE already compatible."
  else
    echo "Adding shape compatibility: $SHAPE"
    oci compute image-shape-compatibility-entry add \
      --image-id "$img_id" --shape-name "$SHAPE" >/dev/null
  fi
}

# Force the image to boot UEFI. A1 (ARM) has no legacy BIOS, but OCI defaults
# custom imports to BIOS firmware - so an unmodified import "runs" at the
# hypervisor level while the guest never boots (empty serial console, no join).
# There is no import/update flag for firmware; it is set via a per-image
# capability schema. The `oci compute image-capability-schema` CLI hangs in some
# environments, so use a signed raw REST call. Idempotent: a repeat create
# returns "already has ... schema", which we treat as success.
ensure_uefi_firmware() {
  local img_id="$1" gver body resp
  gver="$(oci compute global-image-capability-schema list \
    --query 'data[0]."current-version-name"' --raw-output 2>/dev/null)"
  [ -n "$gver" ] || { echo "could not resolve global image capability schema version" >&2; exit 1; }
  body="$(python3 -c 'import json,sys;print(json.dumps({
    "compartmentId": sys.argv[1], "imageId": sys.argv[2],
    "computeGlobalImageCapabilitySchemaVersionName": sys.argv[3],
    "schemaData": {"Compute.Firmware": {"descriptorType":"enumstring","source":"IMAGE","defaultValue":"UEFI_64","values":["UEFI_64"]}}}))' \
    "$COMPARTMENT" "$img_id" "$gver")"
  resp="$(oci raw-request --http-method POST \
    --target-uri "${IAAS}/20160918/computeImageCapabilitySchemas" \
    --request-body "$body" 2>&1 || true)"
  if echo "$resp" | grep -q 'UEFI_64\|already has an image capability schema'; then
    echo "Firmware UEFI_64 set (capability schema)."
  else
    echo "Failed to set UEFI firmware capability schema:" >&2
    echo "$resp" | head -c 600 >&2; echo >&2
    exit 1
  fi
}

# 1. Resolve the schematic ID (Image Factory returns a stable ID per YAML).
SCHEMATIC_ID="$(printf '%s' "$SCHEMATIC_YAML" \
  | curl -fsSL -X POST --data-binary @- https://factory.talos.dev/schematics \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')"
echo "Schematic ID:              $SCHEMATIC_ID"
echo "ocifree schematic for talos/cluster.yaml: ${SCHEMATIC_ID}"

# 2. Idempotency - skip only if an AVAILABLE image matches BOTH the version (its
#    display name) AND the current schematic (stored as a freeform tag). A
#    changed extension set keeps the same name but a new schematic, so the stale
#    image is deleted and rebuilt.
EXISTING="$(oci compute image list --compartment-id "$COMPARTMENT" \
  --display-name "$IMG_NAME" --all 2>/dev/null \
  | python3 -c 'import sys,json
s=sys.stdin.read().strip()
d=(json.loads(s).get("data",[]) if s else [])
a=[i for i in d if i["lifecycle-state"]=="AVAILABLE"]
print(a[0]["id"]+"|"+((a[0].get("freeform-tags") or {}).get("schematic","")) if a else "")')"
EXISTING_ID="${EXISTING%%|*}"
EXISTING_SCHEMATIC="${EXISTING#*|}"
if [ -n "$EXISTING_ID" ]; then
  if [ "$EXISTING_SCHEMATIC" = "$SCHEMATIC_ID" ]; then
    echo "Already AVAILABLE, schematic matches: $EXISTING_ID"
    ensure_shape_compat "$EXISTING_ID"
    ensure_uefi_firmware "$EXISTING_ID"
    echo "Nothing else to do."
    exit 0
  fi
  echo "Existing image $EXISTING_ID has a stale schematic; deleting and rebuilding."
  oci compute image delete --image-id "$EXISTING_ID" --force >/dev/null
fi

# 3. Download the Oracle arm64 qcow2 from Image Factory.
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
QCOW="$WORK/${IMG_NAME}.qcow2"
URL="https://factory.talos.dev/image/${SCHEMATIC_ID}/${VERSION}/${PLATFORM}-${ARCH}.qcow2"
echo "Downloading $URL"
curl -fSL --retry 3 -o "$QCOW" "$URL"

# 3b. Convert to a stream-optimized VMDK. The raw qcow2 does not boot on OCI:
# imported as QCOW2 the firmware probe misfires (UEFI drops to a UEFI shell).
# The streamOptimized VMDK imports clean; firmware is then forced to UEFI_64
# below (see ensure_uefi_firmware - BIOS never boots on arm64).
VMDK="$WORK/${IMG_NAME}.vmdk"
echo "Converting qcow2 -> streamOptimized VMDK..."
qemu-img convert -f qcow2 -O vmdk -o subformat=streamOptimized "$QCOW" "$VMDK"

# 4. Upload the VMDK to object storage.
echo "Uploading to bucket '$BUCKET'..."
oci os object put --bucket-name "$BUCKET" --file "$VMDK" --name "${IMG_NAME}.vmdk" --force >/dev/null

# 5. Import as a PARAVIRTUALIZED custom image.
NS="$(oci os ns get | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"])')"
echo "Importing custom image..."
IMG_ID="$(oci compute image import from-object \
  --compartment-id "$COMPARTMENT" --namespace "$NS" --bucket-name "$BUCKET" \
  --name "${IMG_NAME}.vmdk" --display-name "$IMG_NAME" \
  --launch-mode PARAVIRTUALIZED --source-image-type VMDK \
  --operating-system Talos --operating-system-version "${VERSION#v}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["id"])')"
echo "Import started: $IMG_ID"

# 6. Wait for AVAILABLE, then tag it (OS label + schematic for idempotency).
printf 'Waiting for AVAILABLE'
until [ "$(oci compute image get --image-id "$IMG_ID" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["lifecycle-state"])')" = "AVAILABLE" ]; do
  printf '.'; sleep 20
done
echo ' done.'
oci compute image update --image-id "$IMG_ID" \
  --operating-system "Talos" --operating-system-version "${VERSION#v}" \
  --freeform-tags "{\"schematic\":\"${SCHEMATIC_ID}\"}" --force >/dev/null
ensure_shape_compat "$IMG_ID"
ensure_uefi_firmware "$IMG_ID"
echo "Image ready: $IMG_NAME ($IMG_ID)"
