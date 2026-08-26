# Anbernic RG40XX V

| | |
|---|---|
| SoC | Allwinner H700 |
| Screen | 4", 640×480, vertical |
| Shipped card | 64 GB microSD (62,534,975,488 bytes) |
| Boot logo | 640×480 BMP, generic Anbernic mark |

## Card layout

The stock 64 GB card carries a GPT with seven partitions:

| Partition | Size | Filesystem | Contents |
|---|---|---|---|
| 1 | 47.2 GB | FAT/exFAT | share — `Roms/`, `Music/`, `saves_RA/`, `states_RA/`, `save/`, `.config/` |
| 2 | 33.6 MB | FAT | boot — `bootlogo.bmp`, `fastbootlogo.bmp`, `magic.bin`, `font24.sft`, `font32.sft`, `bat/` |
| 3 | 16.8 MB | — | does not mount on macOS |
| 4 | 67.1 MB | — | does not mount on macOS |
| 5 | 7.5 GB | ext4 | Linux OS |
| 6 | 4.3 GB | ext4 | Linux OS |
| 7 | 2.7 GB | ext4 | Linux OS |

Roughly 645 MB is left unallocated at the end of the disk.

### The asymmetry that drives every backup decision

On a typical unit the share partition holds well under a gigabyte despite being 47 GB.
So the card divides into three very unequal parts:

- **Irreplaceable** — saves, states and configuration on partition 1. Often under 1 GB.
  Copy it at file level; it takes under a minute and needs no root.
- **Replaceable** — the ~14.5 GB of OS partitions. Identical across units of the same
  firmware version, so a stock or alternative image substitutes for them.
- **Empty** — the remaining ~46 GB, which is worth imaging only for a byte-exact clone.

Backing up the first category is cheap and should never be skipped. Imaging all three is
a 62.5 GB operation that mostly copies nothing of value. Treat them as separate decisions
rather than one all-or-nothing dump.

## Stock firmware availability

Anbernic publishes a versioned per-model index. Three properties of it constrain what a
restore can actually achieve:

**No 64 GB variant has ever been released.** Every published image is 16 GB. Flashed to
the shipped 64 GB card it restores the OS partitions correctly but leaves a ~1.4 GB share
partition with ~46 GB unallocated. That is a reinstall, not a restore. Whether the stock
OS expands the share partition itself on first boot is *unverified* for this device —
several H700 stock firmwares do, but that is family resemblance, not an observation, and
it has not been tested here.

**Releases before V1.0.8 are hosted on WeTransfer**, which expires within days of upload.
Those links are almost certainly dead. A unit that shipped on an early version cannot get
that exact build back from the vendor.

**No checksums are published for any release.** A download cannot be verified against the
vendor at all. It can only be pinned once acquired, after which the recorded hash guards
against later corruption or substitution — but the first acquisition is unverifiable by
construction.

The practical consequence: for this device the vendor image is a **fallback, not a
backup**. A dump of the device's own OS partitions is the stronger artefact, because it
captures the exact version the unit shipped with, at the exact partition geometry.

## Alternative firmware

Knulli targets this device as `rg40xx-v` and distributes `.img.gz`, which `dd` and
Balena Etcher both consume directly with no intermediate extraction. See
[`firmware.yaml`](firmware.yaml) for catalogued builds and their verified hashes.

## Restore notes

Device identifiers are not stable across replugs — a card that was `disk5` may be `disk6`
after a reconnect. Always re-confirm the target immediately before writing, by both
external-ness and exact byte count, and never from a remembered identifier.

Because the vendor image is 16 GB and the card is 64 GB, the realistic recovery path is
two-stage: flash stock or alternative firmware, then reapply the file-level archive of
partition 1 over the top. That restores saves and configuration onto a clean OS without
needing a full-card image to exist at all.
