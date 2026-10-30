#!/usr/bin/env bash
# Verify a device's catalogued images against the local store.
#
# Read-only: hashes files, writes nothing, touches no device.
# Store location is configuration, not content:
#   META_RETRO_STORE=/path/to/images scripts/verify-store.sh rg40xxv
#
# Every catalogue entry gets a line: held entries are hashed, entries the store
# does not hold are reported as NOT HELD (a known gap, not a failure). Exit 0
# only if every image marked held_locally verified. Missing hashes and missing
# files are reported as blocking, never as passed.
#
# META_RETRO_DEVICES overrides the devices/ directory (used by the tests).

set -uo pipefail

DEVICE="${1:-}"
[ -n "$DEVICE" ] || { echo "usage: $(basename "$0") <device>   (e.g. rg40xxv)" >&2; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOGUE="${META_RETRO_DEVICES:-$ROOT/devices}/$DEVICE/firmware.yaml"
[ -f "$CATALOGUE" ] || { echo "no catalogue for device '$DEVICE' at devices/$DEVICE/firmware.yaml" >&2; exit 2; }

STORE="${META_RETRO_STORE:-}"
[ -n "$STORE" ] || { echo "META_RETRO_STORE is not set — point it at the image store." >&2; exit 2; }
[ -d "$STORE" ] || { echo "META_RETRO_STORE=$STORE is not a directory." >&2; exit 2; }

python3 - "$CATALOGUE" "$STORE" <<'PY'
import hashlib, os, sys, yaml

catalogue, store = sys.argv[1], sys.argv[2]
images = yaml.safe_load(open(catalogue))["images"]

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

held = [i for i in images if i.get("held_locally")]
unheld = [i for i in images if not i.get("held_locally")]

# Report what the store does not hold instead of skipping it silently.
for img in unheld:
    stray = os.path.exists(os.path.join(store, img["filename"])) if img.get("filename") else False
    note = "present in store but not marked held_locally" if stray else "not held locally"
    print(f"NOT HELD  {img['id']}: {note}")

failed = 0
for img in held:
    name = img["filename"]
    path = os.path.join(store, name)
    expect = img.get("sha256")

    if not os.path.exists(path):
        print(f"MISSING   {img['id']}: {name} not in store"); failed += 1; continue
    if not expect:
        # Fail closed: a check that cannot run is blocking, not passing.
        print(f"UNPINNED  {img['id']}: no sha256 recorded — cannot verify"); failed += 1; continue

    size = os.path.getsize(path)
    declared = img.get("size_bytes")
    if declared and size != declared:
        print(f"SIZE      {img['id']}: {size} bytes, catalogue says {declared}"); failed += 1; continue

    actual = sha256(path)
    if actual == expect:
        print(f"OK        {img['id']}: {name}")
    else:
        print(f"MISMATCH  {img['id']}: {name}\n            expected {expect}\n            actual   {actual}")
        failed += 1

print()
print(f"{len(held) - failed}/{len(held)} held verified, {len(unheld)} not held")
sys.exit(1 if failed else 0)
PY
