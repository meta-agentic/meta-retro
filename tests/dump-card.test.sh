#!/usr/bin/env bash
# End-to-end tests for scripts/dump-card.sh on macOS. No mocks, no root.
#
# Source: a file of random bytes attached as a raw disk image, so it appears as
# an external whole disk (/dev/rdiskN) exactly like a card in a USB reader.
# Destination: a small HFS+ volume, so free space can really be driven down to
# the floor while a dump is running.

set -uo pipefail
shopt -s nullglob

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DUMP="$ROOT/scripts/dump-card.sh"
MiB=$((1 << 20))

[ "$(uname)" = Darwin ] || { echo "SKIP: needs macOS (hdiutil, diskutil)"; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dump-card-test.XXXXXX")"
DEVS=()
cleanup() {
  for d in "${DEVS[@]+"${DEVS[@]}"}"; do hdiutil detach -force "$d" >/dev/null 2>&1; done
  rm -rf "$WORK"
}
trap cleanup EXIT

pass=0; fail=0
ok()   { echo "PASS  $1"; pass=$((pass + 1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
bad()  { echo "FAIL  $1"; fail=$((fail + 1)); }
expect_exit() { # name want got
  if [ "$3" -eq "$2" ]; then ok "$1 (exit $3)"; else bad "$1: exit $3, wanted $2"; sed 's/^/      /' "$WORK/err"; fi
}

attach_source() { # bytes -> sets SRC=/dev/rdiskN (no subshell, so DEVS reaches cleanup)
  local raw="$WORK/src-$1.raw" dev
  head -c "$1" /dev/urandom >"$raw"
  dev="$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$raw" | awk 'NR==1{print $1}')"
  DEVS+=("$dev")
  SRC="/dev/r${dev#/dev/}"
}

free_bytes() { python3 -c 'import os,sys; s=os.statvfs(sys.argv[1]); print(s.f_bavail*s.f_frsize)' "$1"; }

hdiutil create -quiet -size 64m -fs HFS+ -volname dumptest -o "$WORK/dest.dmg"
mkdir "$WORK/mnt"
DEST_DEV="$(hdiutil attach -nobrowse -mountpoint "$WORK/mnt" "$WORK/dest.dmg" | awk 'NR==1{print $1}')"
DEVS+=("$DEST_DEV")
DEST="$WORK/mnt"
FREE="$(free_bytes "$DEST")"
echo "destination volume: $DEST, $((FREE / MiB)) MiB free"
echo

attach_source $((24 * MiB)); SRC24="$SRC"
attach_source $((48 * MiB)); SRC48="$SRC"

# --- identity ----------------------------------------------------------------

"$DUMP" --source "$WORK/src-$((24 * MiB)).raw" --expect-bytes $((24 * MiB)) --output "$DEST/a.img" >/dev/null 2>"$WORK/err"
expect_exit "refuses a regular file without --allow-file-source" 3 $?

"$DUMP" --source "$SRC24" --expect-bytes $((24 * MiB + 512)) --output "$DEST/a.img" >/dev/null 2>"$WORK/err"
expect_exit "refuses when byte count differs from expected" 3 $?

"$DUMP" --source /dev/rdisk0 --expect-bytes 1 --output "$DEST/a.img" >/dev/null 2>"$WORK/err"
expect_exit "refuses an internal disk" 3 $?
grep -q "not an external device" "$WORK/err" || bad "internal-disk refusal names the reason"

DEST_SLICE="$(df "$DEST" | awk 'NR==2{print $1}')"
"$DUMP" --source "/dev/r${DEST_SLICE#/dev/}" --expect-bytes 1 --output "$WORK/p.img" >/dev/null 2>"$WORK/err"
expect_exit "refuses a partition ($DEST_SLICE)" 3 $?
check "partition refusal names the reason" grep -q "is a partition" "$WORK/err"

# --- argument validation -----------------------------------------------------

"$DUMP" --source "$SRC24" --expect-bytes $((24 * MiB)) --floor -5G --output "$DEST/a.img" >/dev/null 2>"$WORK/err"
expect_exit "rejects a negative floor" 2 $?
"$DUMP" --source "$SRC24" --expect-bytes $((24 * MiB)) --floor 1M --output "$DEST/a.img" >/dev/null 2>"$WORK/err"
expect_exit "rejects a floor smaller than one write chunk" 3 $?

# --- abort before write: projection exceeds free space ----------------------

"$DUMP" --source "$SRC48" --expect-bytes $((48 * MiB)) --floor 32M --output "$DEST/big.img" >"$WORK/out" 2>"$WORK/err"
expect_exit "refuses when image + floor exceeds free space" 3 $?
visible=("$DEST"/*)
check "nothing was written to the destination" [ "${#visible[@]}" -eq 0 ]
check "read rate reported before refusing" grep -q "^benchmark" "$WORK/out"
check "compression ratio reported before refusing" grep -q "^ratio" "$WORK/out"

# --- checksum: completed dump matches shasum of the image file ---------------

"$DUMP" --source "$SRC24" --expect-bytes $((24 * MiB)) --floor 8M --output "$DEST/ok.img" >"$WORK/out" 2>"$WORK/err"
expect_exit "dumps a card that fits above the floor" 0 $?
emitted="$(awk '/^sha256/{print $2}' "$WORK/out")"
actual="$(shasum -a 256 "$DEST/ok.img" | awk '{print $1}')"
source_sum="$(shasum -a 256 "$WORK/src-$((24 * MiB)).raw" | awk '{print $1}')"
check "emitted checksum matches shasum -a 256 of the image" [ "${emitted:-none}" = "$actual" ]
check "image is byte-identical to the source" [ "$actual" = "$source_sum" ]
sidecar_ok() { (cd "$DEST" && shasum -a 256 -c ok.img.sha256 >/dev/null 2>&1); }
check "sidecar verifies with shasum -c" sidecar_ok
check "no .partial left after success" [ ! -e "$DEST/ok.img.partial" ]
rm -f "$DEST/ok.img" "$DEST/ok.img.sha256"

# --- abort mid-run: free space crosses the floor while dumping ---------------
# The same dump that just succeeded is rerun while another writer fills the
# volume, leaving 8 MiB of headroom above the floor for a 24 MiB image.

FREE="$(free_bytes "$DEST")"
FILL_MIB=$(( (FREE - 8 * MiB - 8 * MiB) / MiB ))
META_RETRO_DUMP_CHUNK_DELAY=0.25 \
  "$DUMP" --source "$SRC24" --expect-bytes $((24 * MiB)) --floor 8M --output "$DEST/mid.img" >"$WORK/out" 2>"$WORK/err" &
pid=$!
for _ in $(seq 1 200); do [ -e "$DEST/mid.img.partial" ] && break; sleep 0.02; done
check "dump started writing before space was taken (.partial present)" [ -e "$DEST/mid.img.partial" ]
dd if=/dev/zero of="$DEST/filler" bs=1m count="$FILL_MIB" 2>/dev/null
wait "$pid"
expect_exit "aborts when free space crosses the floor mid-run" 4 $?
check "abort reason is the floor, not ENOSPC" grep -q "crossed the floor" "$WORK/err"
check "partial image removed" [ ! -e "$DEST/mid.img.partial" ]
check "no image left under the final name" [ ! -e "$DEST/mid.img" ]
check "destination still above the floor after abort" [ "$(free_bytes "$DEST")" -ge $((8 * MiB)) ]
rm -f "$DEST/filler"

# --- interrupted runs clean up too ------------------------------------------

start_slow_dump() { # name -> sets pid once the .partial exists
  META_RETRO_DUMP_CHUNK_DELAY=0.2 \
    "$DUMP" --source "$SRC24" --expect-bytes $((24 * MiB)) --floor 8M --output "$DEST/$1.img" >/dev/null 2>"$WORK/err" &
  pid=$!
  for _ in $(seq 1 200); do [ -e "$DEST/$1.img.partial" ] && break; sleep 0.02; done
}
no_leftovers() { [ ! -e "$DEST/$1.img.partial" ] && [ ! -e "$DEST/$1.img" ] && [ ! -e "$DEST/$1.img.sha256" ]; }

start_slow_dump int
kill -TERM "$pid"
wait "$pid"
expect_exit "SIGTERM mid-run aborts" 4 $?
check "interrupted run leaves no partial image" no_leftovers int

# A second signal must not interrupt the cleanup the first one started.
orphaned=0
for i in 1 2 3 4 5; do
  start_slow_dump "dbl$i"
  kill -TERM "$pid"; kill -TERM "$pid"
  wait "$pid"
  no_leftovers "dbl$i" || orphaned=$((orphaned + 1))
done
check "double SIGTERM leaves nothing behind (5 runs, $orphaned orphaned)" [ "$orphaned" -eq 0 ]

start_slow_dump hupterm
kill -HUP "$pid"; kill -TERM "$pid"; kill -HUP "$pid"
wait "$pid"
expect_exit "SIGHUP then SIGTERM aborts once" 4 $?
check "SIGHUP then SIGTERM leaves nothing behind" no_leftovers hupterm

# Under nohup (SIGHUP ignored on entry) a hangup must not stop the dump.
(trap '' HUP; META_RETRO_DUMP_CHUNK_DELAY=0.2 exec "$DUMP" --source "$SRC24" --expect-bytes $((24 * MiB)) \
  --floor 8M --output "$DEST/nohup.img" >/dev/null 2>"$WORK/err") &
pid=$!
for _ in $(seq 1 200); do [ -e "$DEST/nohup.img.partial" ] && break; sleep 0.02; done
kill -HUP "$pid"
wait "$pid"
expect_exit "ignored SIGHUP (nohup) does not stop the dump" 0 $?
check "dump under nohup completed with its checksum" [ -e "$DEST/nohup.img.sha256" ]
rm -f "$DEST/nohup.img" "$DEST/nohup.img.sha256"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
