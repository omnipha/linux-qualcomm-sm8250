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

## Matched boot inputs: `sdx55-stage.sh`

The SDX55M loader asks the firmware loader for `qcom/sdx55m/<image>` both
for the BHI SBL (`mhi_qcom_sdx55_flashless_info.fw`) and for every Sahara
image (`drivers/bus/mhi/host/sahara.c`, `sdx55_image_table[]`). The loader
returns the first hit in its search order
(`drivers/base/firmware_loader/main.c`, `fw_path[]`):

```
/lib/firmware/updates/$(uname -r)
/lib/firmware/updates
/lib/firmware/$(uname -r)
/lib/firmware
```

`sdx55-stage.sh` uses that order to place a matched set of boot inputs in
`/lib/firmware/updates/$(uname -r)/qcom/sdx55m/`, where it shadows the
installed set for the next boot. The installed files are never modified,
never moved and never deleted; rollback is the removal of the staged
directory. The staged tree is assembled in a temporary directory and
published with a single rename, so the loader sees either the complete
staged set or the untouched installed set, never a mixture.

The set consists of the 13 firmware images of the **booted slot** (the
modem partition the bootloader started, mounted read-only) plus the 4
private inputs of this device: the modem EFS (`mdm1m9kefs1`,
`mdm1m9kefs2`), the OnePlus NV backup (`mdm1oemnvbktmp`) and the DDR
training data (`mdmddr`). The private inputs are copied with mode 600
into a staged directory of mode 700. They stay on the device: the script
never prints, hashes or copies them anywhere else.

### Run procedure

```sh
# 1. mount the booted slot read-only (slot suffix from the kernel
#    command line; the script uses the same detection)
mount -o ro /dev/disk/by-partlabel/modem_a /run/sdx55-modem_a

# 2. stage the matched set (the installed set stays untouched)
sh Documentation/instantnoodlep/sdx55-stage.sh stage

# 3. check what the loader will pick up
sh Documentation/instantnoodlep/sdx55-stage.sh status
sh Documentation/instantnoodlep/sdx55-stage.sh verify

# 4. rollback, whenever the boot test is over
sh Documentation/instantnoodlep/sdx55-stage.sh restore
```

`stage` refuses to publish a set that does not cover every image the
loader asks for, so the staged set can never mix with the installed one.
`status` prints only which directory each image resolves to; `verify`
checks the resolution and the file modes. Neither prints file contents,
hashes, addresses or kernel log lines.

### Scope

The script writes only inside `/lib/firmware/updates/`. It writes no
partition, does not reboot, does not touch the modem, and does not change
the installed firmware. Running `stage` and the boot test it is meant for
is the owner's decision.

## Issue history

The SDX55M modem boot work is tracked in issue #4 of this repository.
