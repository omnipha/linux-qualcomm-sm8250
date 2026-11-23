#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
#
# Read-only MHI/Sahara boot trace for the flashless SDX55M on the
# OnePlus 8 Pro (instantnoodlep).
#
# Captures, in one report:
#   - the MHI debugfs state of every controller, with the modem controller
#     (events, channels, regdump, states, devices) printed in full
#   - the modem PCIe event IRQ counts before and after a short idle window
#   - the presence of the mhi0_* client devices, /dev/wwan* and
#     /sys/class/wwan
#   - a dmesg excerpt filtered to MHI/Sahara/SDX55 lines
#
# This script only reads and prints. It never writes to a sysfs or debugfs
# knob, never unbinds or rebinds a driver, never loads or unloads a module,
# never touches firmware, partitions or the modem. Root is needed only
# because the MHI debugfs files live under /sys/kernel/debug.
#
# Usage:
#   sh mhi-sahara-trace.sh [OUTPUT_FILE]
#
# With OUTPUT_FILE the report is written there as well; the report is
# always printed to standard output.
#
# Environment:
#   MHI_DBG_DIR    MHI debugfs root (default /sys/kernel/debug/mhi)
#   IDLE_SECONDS   idle window between the two IRQ samples (default 10)

OUTPUT="${1:-}"
MHI_DBG_DIR="${MHI_DBG_DIR:-/sys/kernel/debug/mhi}"
IDLE_SECONDS="${IDLE_SECONDS:-10}"

emit() {
	printf '%s\n' "$*"
}

hr() {
	printf '%s\n' "------------------------------------------------------------"
}

# Count the modem MHI event IRQs in the current /proc/interrupts snapshot.
#
# The MHI event rings are requested with the handler name "mhi" and the
# BHI interrupt vector with "bhi" (drivers/bus/mhi/host/init.c). The MSI
# chip name in /proc/interrupts embeds the PCI BDF of the endpoint, so
# matching on the modem BDF plus the handler name scopes the count to the
# SDX55M and leaves out the QCA6390 and the remoteproc IRQs.
modem_irq_lines() {
	[ -r /proc/interrupts ] || return 1
	[ -n "$MODEM_BDF" ] || return 1

	grep -F "$MODEM_BDF" /proc/interrupts 2>/dev/null | \
		grep -E '[[:space:]](mhi|bhi)[[:space:]]*$'
}

# Sum every per-CPU counter of the selected lines. The IRQ number and the
# trailing chip/handler columns must be skipped: split() on whitespace
# leaves a leading empty field for the indented IRQ number, and the handler
# name stops the count loop.
modem_irq_total() {
	modem_irq_lines 2>/dev/null | awk '
	{
		s = $0
		sub(/^[^:]*:/, "", s)
		n = split(s, f, /[ \t]+/)
		sum = 0
		for (i = 1; i <= n; i++) {
			if (f[i] == "")
				continue
			if (f[i] ~ /^[0-9]+$/)
				sum += f[i]
			else
				break
		}
		total += sum
	}
	END { print total + 0 }'
}

run_report() {

# --- provenance -----------------------------------------------------------
emit "MHI/Sahara boot trace (read-only)"
emit "kernel   : $(uname -r)   host: $(uname -n)"
emit "date     : $(date -u 2>/dev/null || echo 'n/a') UTC"
emit "mhi_dbg  : ${MHI_DBG_DIR}"
emit "idle_secs: ${IDLE_SECONDS}"
emit "WARNING  : this report contains raw IOVA values and kernel pointer"
emit "           values taken from debugfs. Keep it local. Do not paste it"
emit "           into a public issue, a commit or a chat channel."
hr

# --- locate the modem PCI endpoint ---------------------------------------
# The flashless module reports vendor 0x17cb. In PBL/SBL it reports device
# 0x0306; a flashed module reports 0x010c. Accept both so the script keeps
# working if the modem ever gets past the bootloader.
MODEM_BDF=""
for d in /sys/bus/pci/devices/*; do
	[ -r "$d/vendor" ] || continue
	v="$(cat "$d/vendor" 2>/dev/null)"
	dev="$(cat "$d/device" 2>/dev/null)"
	[ "$v" = "0x17cb" ] || continue
	case "$dev" in
	0x0306|0x010c)
		MODEM_BDF="$(basename "$d")"
		emit "modem_pci  : ${MODEM_BDF} (vendor ${v} device ${dev})"
		;;
	esac
done
[ -n "$MODEM_BDF" ] || emit "modem_pci  : NOT FOUND (no 17cb:0306/010c endpoint)"
hr

# --- map the MHI controllers to their PCI endpoints -----------------------
# The debugfs directory name equals the MHI controller device name (mhi0,
# mhi1, ...). The QCA6390 also registers an MHI controller, so the modem
# controller has to be told apart by the PCI endpoint it sits behind.
ctl_bdf() {
	readlink -f "/sys/bus/mhi/devices/$1" 2>/dev/null | \
		sed -n 's#.*\([0-9a-fA-F]\{4\}:[0-9a-fA-F]\{2\}:[0-9a-fA-F]\{2\}\.[0-9a-fA-F]\).*#\1#p'
}

emit "MHI controllers under ${MHI_DBG_DIR}:"
CTL_MODEM=""
if [ -d "$MHI_DBG_DIR" ]; then
	any=0
	for ctl in "$MHI_DBG_DIR"/*; do
		[ -d "$ctl" ] || continue
		any=1
		name="$(basename "$ctl")"
		bdf="$(ctl_bdf "$name")"
		mark=""
		if [ -n "$MODEM_BDF" ] && [ "$bdf" = "$MODEM_BDF" ]; then
			mark="   <= MODEM"
			CTL_MODEM="$ctl"
		fi
		emit "  ${name} -> pci ${bdf:-unknown}${mark}"
	done
	[ "$any" = 1 ] || emit "  (no controller directory: MHI not up, or CONFIG_MHI_BUS_DEBUG is missing)"
else
	emit "  (absent: ${MHI_DBG_DIR})"
fi
[ -n "$CTL_MODEM" ] || emit "  (modem controller directory not identified)"
hr

# --- MHI debugfs, read-only ------------------------------------------------
dump_ctl() {
	ctl="$1"
	for f in states events regdump channels devices; do
		if [ -r "${ctl}/${f}" ]; then
			emit "== $(basename "$ctl")/${f} =="
			cat "${ctl}/${f}" 2>/dev/null || emit "  (read failed)"
			hr
		fi
	done
}

# The modem controller first, then every other controller, so the report
# still contains the modem data if the BDF mapping above did not work.
if [ -n "$CTL_MODEM" ]; then
	emit "--- modem controller ---"
	dump_ctl "$CTL_MODEM"
fi
if [ -d "$MHI_DBG_DIR" ]; then
	for ctl in "$MHI_DBG_DIR"/*; do
		[ -d "$ctl" ] || continue
		[ "$ctl" = "$CTL_MODEM" ] && continue
		emit "--- other controller ---"
		dump_ctl "$ctl"
	done
fi

# --- how to read the control event ring -----------------------------------
emit "How to read the control event ring (see Documentation/instantnoodlep/README.md)"
emit "  - the events file lists, per ring, the IOVA values base/rp/wp and"
emit "    the host consumption pointer as a kernel virtual address"
emit "  - er_ctxt->rp is written by the DEVICE (producer position)"
emit "  - er_ctxt->wp is written by the HOST (space made available)"
emit "  - the host consumption pointer is a virtual address and the file"
emit "    does NOT print the local ring base, so it cannot be normalised"
emit "    into the IOVA domain with the present interface"
emit "  - therefore 'rp == wp' does NOT mean 'no event pending' and"
emit "    'rp != wp' does NOT mean 'the host missed an event'"
emit "  - the pending test the driver itself uses is:"
emit "        mhi_to_virtual(er_ctxt->rp) != ring->rp"
emit "    with mhi_to_virtual(addr) = (addr - iommu_base) + ring->base"
emit "    (drivers/bus/mhi/host/main.c). That comparison needs the local"
emit "    ring base, which the debugfs interface does not export yet."
hr

# --- modem event IRQ counts, before and after the idle window -------------
emit "modem event IRQs (handler mhi/bhi on ${MODEM_BDF:-unknown}):"
if modem_irq_lines 2>/dev/null | grep -q .; then
	modem_irq_lines | awk '{ print "  " $0 }'
else
	emit "  (no modem MHI IRQ line found)"
fi
BEFORE="$(modem_irq_total)"
emit "IRQ_BEFORE : ${BEFORE:-0}"
emit "idle       : sleeping ${IDLE_SECONDS}s, nothing is touched"
sleep "$IDLE_SECONDS" 2>/dev/null
AFTER="$(modem_irq_total)"
emit "IRQ_AFTER  : ${AFTER:-0}"
emit "IRQ_DELTA  : $(( ${AFTER:-0} - ${BEFORE:-0} ))"
emit "modem event IRQs (final snapshot):"
if modem_irq_lines 2>/dev/null | grep -q .; then
	modem_irq_lines | awk '{ print "  " $0 }'
else
	emit "  (no modem MHI IRQ line found)"
fi
hr

# --- MHI client devices and wwan presence ---------------------------------
emit "MHI devices under /sys/bus/mhi/devices:"
if [ -d /sys/bus/mhi/devices ]; then
	ls -1 /sys/bus/mhi/devices 2>/dev/null || emit "  (list failed)"
else
	emit "  (directory absent)"
fi
emit ""
emit "mhi0_* client devices:"
any=0
for p in /sys/bus/mhi/devices/mhi0_*; do
	[ -e "$p" ] || continue
	emit "  $(basename "$p")"
	any=1
done
[ "$any" = 1 ] || emit "  (none)"
emit ""
emit "/dev/wwan*:"
any=0
for p in /dev/wwan*; do
	[ -e "$p" ] || continue
	emit "  $p"
	any=1
done
[ "$any" = 1 ] || emit "  (none)"
emit ""
emit "/sys/class/wwan:"
if [ -d /sys/class/wwan ]; then
	ls -1 /sys/class/wwan 2>/dev/null || emit "  (empty)"
else
	emit "  (directory absent: CONFIG_WWAN off, or no wwan device)"
fi
hr

# --- dmesg excerpt ---------------------------------------------------------
emit "dmesg excerpt (mhi | sahara | sdx55 | wwan | EE | mission mode):"
if dmesg 2>/dev/null | grep -iE 'mhi|sahara|sdx55|wwan|Received EE|EE event|mission mode' >/dev/null 2>&1; then
	dmesg 2>/dev/null | grep -iE 'mhi|sahara|sdx55|wwan|Received EE|EE event|mission mode'
else
	emit "  (no matching dmesg lines, or dmesg not readable)"
fi
hr
emit "end of report"
}

if [ -n "$OUTPUT" ]; then
	run_report | tee "$OUTPUT"
else
	run_report
fi
