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
#   sh mhi-sahara-trace.sh [--redact] [OUTPUT_FILE]
#
# With OUTPUT_FILE the report is written there as well; the report is
# always printed to standard output.
#
# --redact prints only ring-relative normalized values: no host name, no
# raw IOVA values, no kernel pointer values, no register values and no
# kernel log excerpt. Use it for a report that is posted to an issue.
#
# Environment:
#   MHI_DBG_DIR    MHI debugfs root (default /sys/kernel/debug/mhi)
#   IDLE_SECONDS   idle window between the two IRQ samples (default 10)

REDACT=0
OUTPUT=""

usage() {
	cat <<'EOF'
Usage: sh mhi-sahara-trace.sh [--redact] [OUTPUT_FILE]

  --redact      print only ring-relative normalized values (no host name,
                no raw IOVA values, no kernel pointer values, no register
                values, no kernel log excerpt)
  OUTPUT_FILE   optional file the report is written to as well

Environment: MHI_DBG_DIR, IDLE_SECONDS
EOF
}

for arg in "$@"; do
	case "$arg" in
	--redact)
		REDACT=1
		;;
	-h|--help)
		usage
		exit 0
		;;
	-*)
		printf 'unknown option: %s\n' "$arg" >&2
		usage >&2
		exit 2
		;;
	*)
		if [ -z "$OUTPUT" ]; then
			OUTPUT="$arg"
		else
			printf 'unexpected argument: %s\n' "$arg" >&2
			usage >&2
			exit 2
		fi
		;;
	esac
done

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

# Print the rings of one debugfs file as ring-relative values only.
#
# The 'events' and 'channels' files of the MHI debugfs print, per ring, the
# ring base, the ring length and the read pointer (rp) and the write
# pointer (wp) in the IOVA domain of the device, plus the local host
# pointers as kernel virtual addresses. The pending test of the driver
# needs the local ring base, which the interface does not export, so the
# raw values cannot be compared with each other.
#
# What can be normalised without any address: the offset of a pointer
# inside its own ring, (value - base) mod len, is a byte count that
# carries no address and is the same in every domain.
#
# For an event ring rp is the device (producer) and wp the host (space
# made available), so the bytes the device produced beyond the position
# the host has released are (rp_off - wp_off) mod len. The host advances
# its published pointer together with its local one, so this is the
# distance the driver's own pending test measures, in bytes.
#
# For a channel TRE ring rp is the device (consumer) and wp the host
# (producer), so the bytes the host produced that the device has not read
# yet are (wp_off - rp_off) mod len.
#
# Arguments: ring kind (event or channel), debugfs file.
ring_lines() {
	kind="$1"
	file="$2"

	[ -r "$file" ] || return 0

	awk -v kind="$kind" '
	{
		# Drop the local host pointers, they are kernel addresses.
		line = $0
		sub(/ local rp:.*/, "", line)

		base = ""; len = ""; rp = ""; wp = ""; name = ""
		n = split(line, f, /[ \t]+/)
		for (i = 1; i <= n; i++) {
			if (f[i] == "base:")
				base = f[i + 1]
			else if (f[i] == "len:")
				len = f[i + 1]
			else if (f[i] == "rp:")
				rp = f[i + 1]
			else if (f[i] == "wp:")
				wp = f[i + 1]
		}

		if (base == "" || len == "" || rp == "" || wp == "")
			next

		if (kind == "event") {
			if (match(line, /Index: [0-9]+/))
				name = "ring" substr(line, RSTART + 7, RLENGTH - 7)
			else
				name = "ring?"
		} else {
			if (match(line, /^[^ ]+\([0-9]+\)/))
				name = substr(line, RSTART, RLENGTH)
			else
				name = "chan?"
		}

		print name, base, len, rp, wp
	}' "$file" | while read -r nm b l r w; do
		[ -n "$nm" ] || continue
		# Shell arithmetic is signed 64-bit: skip a value with the top
		# bit set instead of computing a wrapped offset from it. On this
		# device the IOVAs are 32-bit, so this never fires in practice.
		ok=1
		for v in "$b" "$l" "$r" "$w"; do
			d="${v#0x}"
			case "$d" in
			""|*[!0-9a-f]*)
				ok=0
				;;
			*)
				if [ "${#d}" -ge 16 ]; then
					case "$d" in
					[89a-f]*) ok=0 ;;
					esac
				fi
				;;
			esac
		done
		[ "$ok" = 1 ] || {
			printf '  %-11s (value out of signed range, not normalized)\n' "$nm"
			continue
		}
		base_n=$(( $b ))
		len_n=$(( $l ))
		rp_n=$(( $r ))
		wp_n=$(( $w ))
		[ "$len_n" -gt 0 ] || continue
		rp_off=$(( (rp_n - base_n) % len_n ))
		wp_off=$(( (wp_n - base_n) % len_n ))
		[ "$rp_off" -ge 0 ] || rp_off=$(( rp_off + len_n ))
		[ "$wp_off" -ge 0 ] || wp_off=$(( wp_off + len_n ))
		if [ "$kind" = event ]; then
			pending=$(( (rp_off - wp_off + len_n) % len_n ))
			note="device produced, host not taken yet"
		else
			pending=$(( (wp_off - rp_off + len_n) % len_n ))
			note="host queued, device not read yet"
		fi
		if [ "$pending" -eq 0 ]; then
			note="nothing pending"
		fi
		printf '  %-11s len=%d rp_off=%d wp_off=%d pending=%d (%s)\n' \
			"$nm" "$len_n" "$rp_off" "$wp_off" "$pending" "$note"
	done
}

run_report() {

# --- provenance -----------------------------------------------------------
emit "MHI/Sahara boot trace (read-only)"
emit "kernel   : $(uname -r)"
emit "date     : $(date -u 2>/dev/null || echo 'n/a') UTC"
emit "mhi_dbg  : ${MHI_DBG_DIR}"
emit "idle_secs: ${IDLE_SECONDS}"
if [ "$REDACT" = 1 ]; then
	emit "mode     : redact (ring-relative normalized values only)"
	emit "WARNING  : the full report of this script contains raw IOVA values"
	emit "           and kernel pointer values taken from debugfs. Keep it"
	emit "           local. Do not paste it into a public issue, a commit or"
	emit "           a chat channel. This run is redacted: it shows only"
	emit "           ring-relative offsets, and it omits the register values,"
	emit "           the raw ring pointers, the kernel log and the host name."
else
	emit "WARNING  : this report contains raw IOVA values and kernel pointer"
	emit "           values taken from debugfs. Keep it local. Do not paste it"
	emit "           into a public issue, a commit or a chat channel."
fi
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
	name="$(basename "$ctl")"

	if [ "$REDACT" = 1 ]; then
		# Only the sections without any address: the controller state
		# and the client devices. The rings follow below as
		# ring-relative offsets.
		if [ -r "${ctl}/states" ]; then
			emit "== ${name}/states =="
			cat "${ctl}/states" 2>/dev/null || emit "  (read failed)"
			hr
		fi
		if [ -r "${ctl}/events" ]; then
			emit "== ${name}/events (ring-relative) =="
			ring_lines event "${ctl}/events"
			hr
		fi
		if [ -r "${ctl}/channels" ]; then
			emit "== ${name}/channels (ring-relative) =="
			ring_lines channel "${ctl}/channels"
			hr
		fi
		if [ -r "${ctl}/devices" ]; then
			emit "== ${name}/devices =="
			cat "${ctl}/devices" 2>/dev/null || emit "  (read failed)"
			hr
		fi
		return 0
	fi

	for f in states events regdump channels devices; do
		if [ -r "${ctl}/${f}" ]; then
			emit "== ${name}/${f} =="
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
if [ "$REDACT" = 1 ]; then
	emit "How to read the ring-relative values above"
	emit "  - rp_off is the offset of the read pointer inside the ring,"
	emit "    wp_off the offset of the write pointer, both as a byte count"
	emit "    from the ring start: (value - base) mod len. No address is"
	emit "    part of them, and they are the same in every address domain."
	emit "  - in an event ring rp is written by the DEVICE and wp by the"
	emit "    HOST, so pending = (rp_off - wp_off) mod len is the number of"
	emit "    bytes the device produced that the host has not taken yet"
	emit "  - in a channel TRE ring rp is written by the DEVICE (consumer)"
	emit "    and wp by the HOST (producer), so pending = (wp_off - rp_off)"
	emit "    mod len is the number of bytes the host queued that the device"
	emit "    has not read yet"
	emit "  - pending = 0 in every ring at two samples with no modem IRQ in"
	emit "    between means: the device posted nothing in that window"
	emit "  - a ring that was never started shows rp_off = wp_off = 0"
else
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
	emit "  - run the same script with --redact to get the pending distance"
	emit "    as a ring-relative byte count instead of raw IOVA values"
fi
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
if [ "$REDACT" = 1 ]; then
	emit "dmesg excerpt: omitted in redact mode (the kernel log may contain"
	emit "raw addresses and device specific values)"
else
	emit "dmesg excerpt (mhi | sahara | sdx55 | wwan | EE | mission mode):"
	if dmesg 2>/dev/null | grep -iE 'mhi|sahara|sdx55|wwan|Received EE|EE event|mission mode' >/dev/null 2>&1; then
		dmesg 2>/dev/null | grep -iE 'mhi|sahara|sdx55|wwan|Received EE|EE event|mission mode'
	else
		emit "  (no matching dmesg lines, or dmesg not readable)"
	fi
fi
hr
emit "end of report"
}

if [ -n "$OUTPUT" ]; then
	run_report | tee "$OUTPUT"
else
	run_report
fi
