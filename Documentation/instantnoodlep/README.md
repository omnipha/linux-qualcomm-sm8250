# OnePlus 8 Pro (instantnoodlep) notes

Measured hardware status is in [STATUS.md](STATUS.md). This file documents
the tools kept in this directory.

## MHI/Sahara boot trace: `mhi-sahara-trace.sh`

The script produces one read-only report of the MHI/Sahara boot state of
the flashless SDX55M: the MHI debugfs state of every controller (modem
controller first, in full), the modem PCIe event IRQ counts before and
after a short idle window, the presence of the `mhi0_*` client devices,
`/dev/wwan*` and `/sys/class/wwan`, and a filtered `dmesg` excerpt. It only
reads and prints; it never writes a sysfs or debugfs knob, never unbinds or
rebinds a driver, never loads or unloads a module, and never touches
firmware, partitions or the modem. Root is needed only because the MHI
debugfs files live under `/sys/kernel/debug`.

### Run procedure

One command, from the root of the source tree on the device (or with the
script copied to the device):

```sh
sh Documentation/instantnoodlep/mhi-sahara-trace.sh
```

The report always goes to standard output. To also write it to a file:

```sh
sh Documentation/instantnoodlep/mhi-sahara-trace.sh /tmp/mhi-trace.txt
```

For a report that is meant to be pasted into a public issue, use the
redacted form instead:

```sh
sh Documentation/instantnoodlep/mhi-sahara-trace.sh --redact
```

`--redact` prints only ring-relative normalized values: no host name, no
raw IOVA values, no kernel pointer values, no register values and no
kernel log excerpt. Without `--redact` the report is complete and must
stay local (see the warning below).

Optional environment: `MHI_DBG_DIR` (MHI debugfs root, default
`/sys/kernel/debug/mhi`) and `IDLE_SECONDS` (idle window between the two
IRQ samples, default 10).

### Reading `rp` / `wp`

The `events` and `channels` files of the MHI debugfs print, per ring, the
ring base, the ring length, a read pointer `rp` and a write pointer `wp`
in the IOVA domain of the device, plus the local host pointers as kernel
virtual addresses.

- `rp` is written by the **device** (producer position): the device has
  produced every event before this point of the ring.
- `wp` is written by the **host** (space made available): the host has
  released every entry before this point of the ring.
- The host consumption pointer in the file is a kernel virtual address, and
  the file does not print the local ring base, so it cannot be normalised
  into the IOVA domain with the present interface. Therefore `rp == wp`
  does **not** mean "no event pending" and `rp != wp` does **not** mean
  "the host missed an event" when read directly from the raw file.
- The pending test the driver itself uses is
  `mhi_to_virtual(er_ctxt->rp) != ring->rp`, with
  `mhi_to_virtual(addr) = (addr - iommu_base) + ring->base`
  (`drivers/bus/mhi/host/main.c`). That comparison needs the local ring
  base, which the debugfs interface does not export.
- With `--redact`, the script computes what *can* be normalised without any
  address: the offset of each pointer inside its own ring,
  `(value - base) mod len`, a byte count with no address in it. For an
  event ring the device produces and the host consumes, so
  `pending = (prod_off - host_off) mod len` is the number of bytes the
  device produced that the host has not taken yet; for a channel TRE ring
  the host produces and the device consumes, so
  `pending = (host_off - prod_off) mod len`. `pending = 0` in every ring at
  two samples with no modem IRQ in between means the device posted nothing
  in that window. A ring that was never started shows
  `prod_off = host_off = 0`.

### Publication safety

The raw `events`, `channels` and `regdump` files contain raw IOVA values
and kernel pointer values (the `regdump` output additionally contains
device register values). The full report of this script therefore contains
raw IOVA values and kernel pointer values taken from debugfs. **Keep it
local. Do not paste it into a public issue, a commit or a chat channel.**
Use `--redact` for anything that leaves the device.

## Issue history

The SDX55M modem boot work is tracked in issue #4 of this repository.
