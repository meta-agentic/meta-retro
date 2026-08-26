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

## Status

The device profiles and the firmware catalogue are in place. The dump, verify and flash
tooling is specified and tracked, and deliberately not yet published here: an earlier
ad-hoc version lacked the compression preflight and free-space floor described above,
and shipping it would propagate the exact failure this project exists to prevent.

## Licence

MIT — see [LICENSE](LICENSE).
