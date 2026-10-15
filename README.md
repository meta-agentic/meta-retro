# meta-retro

Firmware and OS lifecycle management for retro handheld devices.

Per-device profiles, a checksum-verified catalogue of stock and alternative images, and
tooling to dump, verify and flash SD cards without the failure modes that make backups
quietly worthless.

The invariant the whole thing serves:

> **An image is not a backup until it has been verified to read back to the checksum of
> what was read from the card.**

A file that exists, has a plausible size, and is silently truncated is the failure this
project is built to prevent. Every check here fails closed: a verification that cannot
run because its input is missing registers as *unknown and blocking*, never as *passed*.

## Why this exists

Backing up a handheld's SD card looks like a one-liner and is not. Three assumptions
that seem safe are all false in practice, and each of them was measured rather than
guessed:

**Free space does not compress.** A 64 GB card with 686 MB used looks like it should
compress to nothing. Measured on a real device: 228 MB read produced 241 MB of gzip
output — a ratio of **1.058**, meaning gzip *expanded* it. The unused sectors were not
zeroed; they held random residue. A dump sized on the optimistic assumption was on
course to fill the host's startup disk and leave a truncated file behind.

**USB port choice is a 5× difference.** The same card and reader measured 3.8 MB/s on
one port and 19.1 MB/s on another — 4.5 hours versus 55 minutes for a full dump.

**Progress reporting lies in a pipeline.** `Ctrl-T` (`SIGINFO`) during
`dd | tee | gzip` reports the wrong process, so a long read appears to have no progress
indicator at all. Cumulative device counters give true position without signalling
anything.

Tooling that does not account for all three produces backups that fail exactly when you
need them.

## Devices

| Device | SoC | Screen | Profile |
|---|---|---|---|
| Anbernic RG40XX V | Allwinner H700 | 4" 640×480 vertical | [`devices/rg40xxv`](devices/rg40xxv/) |

Each device folder holds a hardware and card-layout profile, plus `firmware.yaml` — the
catalogue of every image known for that device, stock and alternative.

## The binary boundary

**No firmware image and no card backup is ever committed to this repository.** Vendor
images are copyrighted redistribution; card dumps carry personal save data; both are
large enough to poison a git history permanently.

The repository holds text only. Images live in a local store outside it, addressed by
SHA-256 from the catalogue. The store's location is configuration, never content — set
`META_RETRO_STORE` to point at it. That keeps every file here publishable and makes a
leak a deliberate act rather than an accident.

## Flashability is a property worth cataloguing

Whether an image can be flashed *directly* is recorded per entry, because it decides
whether a restore is possible on a machine that is short on disk — which is precisely
the situation in which a restore tends to be needed.

- `.img.gz` is consumed directly by both `dd` and Balena Etcher. No scratch space.
- A `.7z` inside a `.zip` must first be expanded to a full-size `.img`. Restoring a
  16 GB image therefore needs 16 GB free before it can begin.

## Dumping a card

`scripts/dump-card.sh` images a whole card to an uncompressed `.img` and refuses to
start a dump it cannot finish:

```sh
sudo scripts/dump-card.sh --source /dev/rdisk5 --expect-bytes 62534975488 \
    --output /Volumes/Backup/rg40xxv-2026-10-15.img
```

1. **Identity.** The source must be an external whole disk of exactly `--expect-bytes`.
   Internal disks, partitions and size mismatches are refused, because device numbers
   change across replugs.
2. **Benchmark.** Samples spread across the card give the read rate and the projected
   duration, so a slow USB port shows up before the run starts, not hours into it.
3. **Ratio.** The same samples are gzipped to measure how well the card compresses. The
   result is reported, not acted on: card residue measured at 1.058, so images are
   written uncompressed and sized at the full card.
4. **Preflight.** Refuses unless free space covers the image plus `--floor` (default
   10G). Nothing is created on refusal.
5. **Dump.** A single process reads, hashes and writes in one pass. Free space is
   checked after every 4 MiB chunk, and the run aborts as soon as it drops below the
   floor, without waiting for `ENOSPC`. On abort or interrupt the `.partial` file is
   deleted, and an image only gets its final name once it is complete.
6. **Checksum.** Writes `<image>.sha256` from the source stream; `shasum -a 256 -c`
   verifies it without a second read of the card.

`Ctrl-T` reports the dump's own progress, because no pipeline sits in between. For an
external view, the tool prints the matching `iostat -Id diskN` command. Pass
`--preflight-only` to compare USB ports without dumping.

`tests/dump-card.test.sh` runs every refusal and abort path for real (no root, no
mocks). It uses a raw disk image attached as an external device for the source and a
64 MiB HFS+ volume for the destination. While a dump is running, a second writer fills
that volume, so free space genuinely crosses the floor mid-run.

## Status

The device profiles, the firmware catalogue, the store verifier and the dump tool are
in place. Flash tooling is specified and tracked, but not published here yet.

## Licence

MIT — see [LICENSE](LICENSE).
