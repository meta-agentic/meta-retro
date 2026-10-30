#!/usr/bin/env bash
# Tests for scripts/verify-store.sh against a synthetic catalogue and store.
# No devices, no real images: META_RETRO_DEVICES points at a temp catalogue.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY="$ROOT/scripts/verify-store.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/verify-store-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/devices/fake" "$WORK/store"

pass=0; fail=0
ok()  { echo "PASS  $1"; pass=$((pass + 1)); }
bad() { echo "FAIL  $1"; fail=$((fail + 1)); }
has() { grep -q -- "$1" "$WORK/out"; }

printf 'good image' >"$WORK/store/good.img"
printf 'tampered' >"$WORK/store/bad.img"
GOOD="$(shasum -a 256 "$WORK/store/good.img" | awk '{print $1}')"

cat >"$WORK/devices/fake/firmware.yaml" <<YAML
device: fake
images:
  - {id: good, filename: good.img, sha256: $GOOD, held_locally: true}
  - {id: gone, filename: gone.img, sha256: $GOOD, held_locally: false}
  - {id: stray, filename: bad.img, sha256: null, held_locally: false}
YAML

run() { META_RETRO_DEVICES="$WORK/devices" META_RETRO_STORE="$WORK/store" "$VERIFY" fake >"$WORK/out" 2>"$WORK/err"; }

run; rc=$?
[ $rc -eq 0 ] && ok "exits 0 when every held image verifies" || bad "exit $rc, wanted 0"
has '^OK  *good' && ok "held image reported OK" || bad "held image not reported OK"
has '^NOT HELD  *gone: not held locally' && ok "unheld entry is reported, not skipped" || bad "unheld entry silent"
has '^NOT HELD  *stray: present in store' && ok "unmarked file in store is flagged" || bad "stray file not flagged"
has '1/1 held verified, 2 not held' && ok "summary counts unheld entries" || bad "summary wrong"

# All entries unheld: still lists them (previously a bare 'nothing to verify').
sed -i.bak 's/held_locally: true/held_locally: false/' "$WORK/devices/fake/firmware.yaml"
run; rc=$?
[ $rc -eq 0 ] && has '^NOT HELD  *good' && ok "all-unheld catalogue still lists every entry" || bad "all-unheld case silent"

# Held but tampered: mismatch is blocking.
sed -i.bak 's/held_locally: false}$/held_locally: true}/;s/good.img/bad.img/' "$WORK/devices/fake/firmware.yaml"
run; rc=$?
[ $rc -eq 1 ] && has '^MISMATCH' && ok "hash mismatch exits 1" || bad "mismatch not blocking (exit $rc)"

# Held but missing from the store.
printf 'device: fake\nimages:\n  - {id: m, filename: nope.img, sha256: abc, held_locally: true}\n' >"$WORK/devices/fake/firmware.yaml"
run; rc=$?
[ $rc -eq 1 ] && has '^MISSING' && ok "held-but-missing exits 1" || bad "missing not blocking (exit $rc)"

echo; echo "$pass passed, $fail failed"
[ $fail -eq 0 ]
