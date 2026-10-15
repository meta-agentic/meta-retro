#!/usr/bin/env bash
# Dump a whole SD card to an uncompressed image, refusing to start when it
# cannot finish and aborting before the destination disk runs dry.
#
#   scripts/dump-card.sh --source /dev/rdisk5 --expect-bytes 62534975488 \
#       --output /Volumes/Backup/rg40xxv-2026-10-15.img
#
# Order of operations, each step fail-closed:
#   1. identity   source must be an external whole disk of exactly --expect-bytes
#   2. benchmark  sample reads across the card: read rate and projected duration
#   3. ratio      gzip the samples to measure compressibility (reported only:
#                 card residue measured at 1.058, so images are written raw)
#   4. preflight  refuse unless free space >= image size + --floor
#   5. dump       single process reads, hashes and writes in one pass; aborts
#                 and deletes the partial file if free space crosses --floor
#   6. emit       renames .partial into place, writes <image>.sha256
#
# Exit codes: 0 done, 2 usage, 3 refused before writing, 4 aborted mid-run.

set -uo pipefail

exec python3 - "$@" <<'PY'
import argparse, hashlib, os, plistlib, signal, stat, subprocess, sys, time, zlib

CHUNK = 4 << 20
FSYNC_EVERY = 64 * CHUNK
EXIT_USAGE, EXIT_REFUSED, EXIT_ABORTED = 2, 3, 4
UNITS = {"": 1, "K": 1 << 10, "M": 1 << 20, "G": 1 << 30, "T": 1 << 40}


class Abort(Exception):
    pass


def size_arg(text):
    t = text.strip().upper().removesuffix("IB").removesuffix("B")
    unit = t[-1] if t and t[-1] in UNITS else ""
    try:
        return int(float(t[: len(t) - len(unit)]) * UNITS[unit])
    except ValueError:
        raise argparse.ArgumentTypeError(f"not a size: {text!r} (e.g. 62534975488, 10G, 512M)")


def human(n):
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if abs(n) < 1024 or unit == "TiB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{n} B"
        n /= 1024


def duration(seconds):
    seconds = int(seconds)
    return f"{seconds // 3600}h{seconds % 3600 // 60:02d}m{seconds % 60:02d}s"


def refuse(msg):
    print(f"REFUSED   {msg}\n          nothing was written.", file=sys.stderr)
    sys.exit(EXIT_REFUSED)


def free_bytes(path):
    st = os.statvfs(path)
    return st.f_bavail * st.f_frsize


def identify(src, expect, allow_file):
    try:
        mode = os.stat(src).st_mode
    except OSError as e:
        refuse(f"cannot stat source {src}: {e.strerror}")
    if stat.S_ISREG(mode):
        if not allow_file:
            refuse(f"{src} is a regular file, not a card. Pass --allow-file-source to image a file.")
        size, label, disk = os.path.getsize(src), "regular file", None
    elif stat.S_ISCHR(mode) or stat.S_ISBLK(mode):
        r = subprocess.run(["diskutil", "info", "-plist", src], capture_output=True)
        if r.returncode != 0:
            refuse(f"diskutil cannot identify {src}")
        info = plistlib.loads(r.stdout)
        if info.get("Internal", True) or not info.get("RemovableMediaOrExternalDevice", False):
            refuse(f"{src} is not an external device — will never image an internal disk.")
        if not info.get("WholeDisk", False):
            refuse(f"{src} is a partition, not a whole disk.")
        size = info.get("TotalSize") or info.get("Size")
        disk = info.get("DeviceIdentifier")
        label = f"{disk}, external, {info.get('BusProtocol', '?')}, {info.get('MediaName', '?')}"
    else:
        refuse(f"{src} is neither a disk device nor a regular file.")
    if size != expect:
        refuse(f"{src} is {size} bytes, expected {expect}. Device numbers change across replugs: re-check which disk the card is.")
    return label, disk


def sample(fd, size, budget):
    n_chunks = max(1, size // CHUNK)
    n = max(1, min(n_chunks, budget // CHUNK))
    offsets = sorted({(n_chunks - 1) * i // max(n - 1, 1) * CHUNK for i in range(n)})
    raw = packed = 0
    read_s = 0.0
    for off in offsets:
        t0 = time.monotonic()
        data = os.pread(fd, min(CHUNK, size - off), off)
        read_s += time.monotonic() - t0
        raw += len(data)
        packed += len(zlib.compress(data, 6))
    return raw, packed, read_s, len(offsets)


class Progress:
    def __init__(self, total):
        self.total, self.pos, self.t0, self.last = total, 0, time.monotonic(), 0.0

    def line(self):
        el = max(time.monotonic() - self.t0, 1e-6)
        rate = self.pos / el
        eta = (self.total - self.pos) / rate if rate else 0
        return (f"progress  {human(self.pos)} / {human(self.total)} ({100 * self.pos / self.total:.1f}%)"
                f"  {rate / 1e6:.1f} MB/s  elapsed {duration(el)}  eta {duration(eta)}")

    def tick(self, every=5.0):
        if time.monotonic() - self.last >= every:
            self.last = time.monotonic()
            print(self.line(), file=sys.stderr, flush=True)


def on_sigterm(*_):
    raise KeyboardInterrupt


def dump(src_fd,out, expect, floor, chunk_delay):
    partial = out + ".partial"
    h = hashlib.sha256()
    prog = Progress(expect)
    signal.signal(signal.SIGINFO, lambda *_: print(prog.line(), file=sys.stderr, flush=True))
    fd = os.open(partial, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        since_sync = 0
        while prog.pos < expect:
            data = os.pread(src_fd, min(CHUNK, expect - prog.pos), prog.pos)
            if not data:
                raise Abort(f"source ended at {prog.pos} bytes, expected {expect} — short read")
            h.update(data)
            view = memoryview(data)
            while view:
                view = view[os.write(fd, view):]
            prog.pos += len(data)
            since_sync += len(data)
            if since_sync >= FSYNC_EVERY:
                os.fsync(fd)
                since_sync = 0
            free = free_bytes(os.path.dirname(partial))
            if free < floor:
                raise Abort(f"free space {human(free)} crossed the floor of {human(floor)} "
                            f"at {human(prog.pos)} of {human(expect)}")
            prog.tick()
            if chunk_delay:
                time.sleep(chunk_delay)
        os.fsync(fd)
        os.close(fd)
        fd = None
        if os.path.getsize(partial) != expect:
            raise Abort(f"image is {os.path.getsize(partial)} bytes on disk, expected {expect}")
        os.rename(partial, out)
    except BaseException as e:
        if fd is not None:
            os.close(fd)
        os.unlink(partial)
        reason = e if isinstance(e, Abort) else (
            "interrupted" if isinstance(e, KeyboardInterrupt) else f"{type(e).__name__}: {e}")
        print(f"ABORTED   {reason}\n          partial image removed: {partial}", file=sys.stderr)
        sys.exit(EXIT_ABORTED)
    print(prog.line(), file=sys.stderr)
    return h.hexdigest()


def main():
    p = argparse.ArgumentParser(prog="dump-card.sh", description="Dump a whole card to a raw image, safely.")
    p.add_argument("--source", required=True, help="card device, e.g. /dev/rdisk5 (raw node is faster)")
    p.add_argument("--expect-bytes", required=True, type=size_arg, help="exact card size; the run refuses on mismatch")
    p.add_argument("--output", required=True, help="image path to create; must not exist")
    p.add_argument("--floor", type=size_arg, default=size_arg("10G"),
                   help="free space the destination must keep at all times (default 10G)")
    p.add_argument("--sample", type=size_arg, default=size_arg("64M"),
                   help="bytes sampled across the card for the rate and ratio preflight (default 64M)")
    p.add_argument("--preflight-only", action="store_true", help="identify, benchmark and size, then stop")
    p.add_argument("--allow-file-source", action="store_true", help="accept a regular file as source")
    a = p.parse_args(sys.argv[1:])

    out = os.path.abspath(a.output)
    if os.path.lexists(out) or os.path.lexists(out + ".partial"):
        refuse(f"{out} (or its .partial) already exists — will not overwrite.")
    if not os.path.isdir(os.path.dirname(out)):
        refuse(f"output directory {os.path.dirname(out)} does not exist.")

    label, disk = identify(a.source, a.expect_bytes, a.allow_file_source)
    print(f"source    {a.source} ({label}), {a.expect_bytes} bytes — matches expected")

    try:
        src_fd = os.open(a.source, os.O_RDONLY)
    except OSError as e:
        refuse(f"cannot open {a.source} for reading: {e.strerror} (raw disk reads need sudo)")

    raw, packed, read_s, n = sample(src_fd, a.expect_bytes, a.sample)
    rate = raw / read_s if read_s > 0 else float("inf")
    eta = a.expect_bytes / rate if rate != float("inf") else 0
    ratio = packed / raw
    print(f"benchmark {human(raw)} in {n} samples at {rate / 1e6:.1f} MB/s — projected duration {duration(eta)}")
    print(f"ratio     gzip {ratio:.3f} on sampled data (projected .gz {human(int(a.expect_bytes * ratio))}); "
          f"image is written uncompressed")

    free = free_bytes(os.path.dirname(out))
    need = a.expect_bytes + a.floor
    print(f"space     image {human(a.expect_bytes)} + floor {human(a.floor)} = {human(need)}; free {human(free)}")
    if need > free:
        refuse(f"projected image does not fit above the floor: short by {human(need - free)}.")
    if a.preflight_only:
        print("preflight passed — stopping (--preflight-only).")
        return
    if disk:
        print(f"monitor   iostat -Id {disk} 10    (cumulative device reads, from another terminal)")
    signal.signal(signal.SIGTERM, on_sigterm)
    signal.signal(signal.SIGHUP, on_sigterm)

    # Test-only: slows each chunk so tests can change free space mid-run on a real volume.
    delay = float(os.environ.get("META_RETRO_DUMP_CHUNK_DELAY", "0") or 0)
    digest = dump(src_fd, out, a.expect_bytes, a.floor, delay)
    with open(out + ".sha256", "w") as f:
        f.write(f"{digest}  {os.path.basename(out)}\n")
    print(f"sha256    {digest}")
    print(f"done      {out}\n          verify: (cd {os.path.dirname(out)} && shasum -a 256 -c {os.path.basename(out)}.sha256)")


main()
PY
