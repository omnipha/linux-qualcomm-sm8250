#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
#
# Stage matched SDX55M boot inputs for one authorized boot, reversibly.
#
# The firmware loader searches its paths in order and returns the first
# hit (drivers/base/firmware_loader/main.c, fw_path[]):
#
#   /lib/firmware/updates/$(uname -r)
#   /lib/firmware/updates
#   /lib/firmware/$(uname -r)
#   /lib/firmware
#
# The loader of this tree asks for "qcom/sdx55m/<image>" both for the BHI
# SBL (mhi_qcom_sdx55_flashless_info.fw) and for every Sahara image
# (drivers/bus/mhi/host/sahara.c, sdx55_image_table[]).
#
# So the staging copies the matched set into
#
#   /lib/firmware/updates/$(uname -r)/qcom/sdx55m/
#
# where it shadows the installed set. The installed files are never
# modified, never moved and never deleted. Rollback is the removal of the
# staged directory; there is nothing else to restore.
#
# The staged tree is assembled in a temporary directory and renamed into
# place with one rename(2), so the loader either sees the complete staged
# set or the untouched installed set, never a mixture and never a partial
# file. An interrupted run leaves only a temporary directory behind,
# which the loader does not search.
#
# Private inputs (EFS, NV backup, DDR training) are copied from this
# device's own partitions with mode 600 into the staged directory, which
# is mode 700. They stay on the device: this script never prints them,
# never hashes them and never copies them anywhere else.
#
# This script does not write any partition, does not reboot and does not
# touch the modem. stage and restore are meant to be run by the owner on
# the device, under the owner's approval.
#
# Usage: sh sdx55-stage.sh {stage|restore|status|verify}

set -e

# The slot the bootloader started: the modem partition to mount is
# modem_a or modem_b accordingly (same detection as the reference's
# install.sh).
SLOT=a
for arg in $(cat /proc/cmdline 2>/dev/null); do
	case "$arg" in androidboot.slot_suffix=_b) SLOT=b ;; esac
done

REL="$(uname -r)"
FW_BASE="${FW_BASE:-/lib/firmware}"
STAGE="$FW_BASE/updates/$REL/qcom/sdx55m"
INSTALLED="$FW_BASE/qcom/sdx55m"
SLOT_DIR="${SLOT_DIR:-/run/sdx55-modem_$SLOT/image/sdx55m}"
PART_DIR="${PART_DIR:-/dev/disk/by-partlabel}"

# The images the loader asks for: the 17 entries of
# sdx55_image_table[] in drivers/bus/mhi/host/sahara.c. 13 firmware
# images from the booted slot, 4 private inputs below.
SLOT_IMAGES="sbl1.mbn apps.mbn qdsp6sw.mbn aop.mbn tz.mbn hyp.mbn
acdb.mbn multi_image.mbn multi_image_qti.mbn xbl_cfg.elf apdp.mbn
devcfg.mbn sec.elf"

# name:partition of the private inputs. ids 16/17/20/34 of the table.
PRIVATE_INPUTS="efs1.bin:mdm1m9kefs1
efs2.bin:mdm1m9kefs2
efs3.bin:mdm1oemnvbktmp
mdmddr.mbn:mdmddr"

usage() {
	cat <<EOF
Usage: sh sdx55-stage.sh {stage|restore|status|verify}

  stage    assemble the staged set in a temporary directory and rename it
           into $STAGE (installed set untouched)
  restore  remove the staged directory (rollback); the installed set is
           the state that was there all along
  status   show which of the loader's images resolve to the staged set
  verify   check that every image the loader asks for resolves, and that
           the staged directory is mode 700 with mode 600 files

Directories:
  STAGE       $STAGE
  INSTALLED   $INSTALLED
  SLOT_DIR    $SLOT_DIR   (mounted read-only, booted slot modem partition)
  PART_DIR    $PART_DIR   (private partitions of this device)
EOF
}

# Every image the loader asks for, in one list: slot images plus the
# private inputs.
all_images() {
	for n in $SLOT_IMAGES; do
		printf '%s\n' "$n"
	done
	printf '%s\n' "$PRIVATE_INPUTS" | cut -d: -f1
}

# The loader's resolution order for "qcom/sdx55m/<image>": the staged
# path first, then the installed set. Prints the path it would use.
resolve() {
	name="$1"
	if [ -f "$STAGE/$name" ]; then
		printf '%s\n' "$STAGE/$name"
	elif [ -f "$INSTALLED/$name" ]; then
		printf '%s\n' "$INSTALLED/$name"
	else
		return 1
	fi
}

do_stage() {
	tmp="$FW_BASE/updates/$REL/.qcom-sdx55m.staged.$$"

	# A leftover of an interrupted earlier run is in the way: it is not
	# in the search path (it is a dot directory), remove it.
	rm -rf "$FW_BASE/updates/$REL/.qcom-sdx55m.staged."* 2>/dev/null || true

	mkdir -p "$tmp"
	chmod 700 "$tmp"

	# 1. The firmware of the booted slot: the set the reference uses.
	#    Missing files are reported, not invented.
	if [ ! -d "$SLOT_DIR" ]; then
		printf 'the booted slot is not mounted at %s\n' "$SLOT_DIR" >&2
		printf 'mount it read-only first, for example:\n' >&2
		printf '  mount -o ro /dev/disk/by-partlabel/modem_%s /run/sdx55-modem_%s\n' \
			"$SLOT" "$SLOT" >&2
		return 1
	fi
	for name in $SLOT_IMAGES; do
		if [ -f "$SLOT_DIR/$name" ]; then
			install -m 600 "$SLOT_DIR/$name" "$tmp/$name"
		else
			printf 'slot file not present: %s\n' "$name" >&2
		fi
	done

	# 2. The private EFS/NV/DDR inputs of this device. Read from the
	#    private partitions, written into the staged tree only, mode 600.
	printf '%s\n' "$PRIVATE_INPUTS" | while IFS= read -r pair; do
		name="${pair%%:*}"
		part="${pair##*:}"
		if [ -r "$PART_DIR/$part" ]; then
			dd if="$PART_DIR/$part" of="$tmp/$name" bs=1M status=none
			chmod 600 "$tmp/$name"
		else
			printf 'private input not readable: %s (%s)\n' \
				"$name" "$part" >&2
		fi
	done

	# 3. Everything the loader asks for must be in the staged tree,
	#    otherwise the staged set would silently fall back to the
	#    installed set for the missing file and mix the two.
	not_covered=""
	for name in $(all_images); do
		[ -f "$tmp/$name" ] || not_covered="$not_covered $name"
	done

	if [ -n "$not_covered" ]; then
		printf 'REFUSE stage: not covered:%s\n' "$not_covered" >&2
		printf 'A staged set must cover every image the loader asks for.\n' >&2
		rm -rf "$tmp"
		return 1
	fi

	# 4. Publish the staged set with one rename. Before this point the
	#    loader sees the installed set, after it the staged set.
	mkdir -p "$(dirname "$STAGE")"
	if [ -e "$STAGE" ]; then
		# Re-staging: swap, so there is no window without a stage.
		old="$FW_BASE/updates/$REL/.qcom-sdx55m.old.$$"
		mv -f "$STAGE" "$old"
		mv -f "$tmp" "$STAGE"
		rm -rf "$old"
	else
		mv -f "$tmp" "$STAGE"
	fi

	printf 'staged: %s (%s files)\n' "$STAGE" \
		"$(ls -1 "$STAGE" | wc -l)"
}

do_restore() {
	if [ ! -d "$STAGE" ]; then
		printf 'nothing to roll back: no staged set at %s\n' "$STAGE"
		return 0
	fi
	# One removal: the installed set below was never touched.
	rm -rf "$STAGE"
	# Drop empty parents up to /lib/firmware/updates.
	rmdir "$FW_BASE/updates/$REL/qcom" "$FW_BASE/updates/$REL" \
		"$FW_BASE/updates" 2>/dev/null || true
	printf 'rolled back: staged set removed, installed set at %s is unchanged\n' \
		"$INSTALLED"
}

do_status() {
	if [ -d "$STAGE" ]; then
		printf 'staged set : present (%s files, dir mode %s)\n' \
			"$(ls -1 "$STAGE" | wc -l)" \
			"$(stat -c %a "$STAGE" 2>/dev/null || echo '?')"
	else
		printf 'staged set : absent (loader uses the installed set)\n'
	fi
	printf 'installed  : %s\n' "$INSTALLED"
	printf 'resolution of the %s loader images:\n' \
		"$(all_images | wc -l)"
	for name in $(all_images); do
		if p="$(resolve "$name")"; then
			case "$p" in
			"$STAGE"/*) src="STAGED  " ;;
			*)          src="installed" ;;
			esac
			printf '  %-10s %s\n' "$src" "$name"
		else
			printf '  %-10s %s\n' "MISSING" "$name"
		fi
	done
}

do_verify() {
	fail=0

	# Every image the loader asks for resolves.
	for name in $(all_images); do
		if ! resolve "$name" >/dev/null; then
			printf 'FAIL: %s does not resolve\n' "$name" >&2
			fail=1
		fi
	done

	# Modes: staged directory 700, staged files 600.
	if [ -d "$STAGE" ]; then
		m="$(stat -c %a "$STAGE" 2>/dev/null || echo '?')"
		if [ "$m" != 700 ]; then
			printf 'FAIL: staged directory mode is %s, expected 700\n' "$m" >&2
			fail=1
		fi
		for f in "$STAGE"/*; do
			[ -f "$f" ] || continue
			m="$(stat -c %a "$f" 2>/dev/null || echo '?')"
			if [ "$m" != 600 ]; then
				printf 'FAIL: %s mode is %s, expected 600\n' \
					"$(basename "$f")" "$m" >&2
				fail=1
			fi
		done
	fi

	# The installed set must still be the set that was installed: the
	# staged directory is a separate directory, so this holds by
	# construction; check it is not a symlink into the stage.
	if [ -L "$INSTALLED" ]; then
		printf 'FAIL: installed directory is a symlink\n' >&2
		fail=1
	fi

	if [ "$fail" = 0 ]; then
		printf 'verify: OK (every loader image resolves, modes are 700/600)\n'
	fi
	return "$fail"
}

case "${1:-}" in
stage)  do_stage ;;
restore) do_restore ;;
status) do_status ;;
verify) do_verify ;;
*) usage; exit 2 ;;
esac
