# Boot image recipe (instantnoodlep)

Verified recipe to turn a kernel built from this tree into a bootable
`boot-candidate.img` for the OnePlus 8 Pro (`instantnoodlep`) and flash it
to the inactive or active boot slot. Everything below was actually run and
measured on one IN2023 (2026-11-24/25), kernel `7.2.0-g6c71d80b5a83`.
Measured status of that unit is in [STATUS.md](STATUS.md).

## 0. Prerequisites

* An unlocked bootloader on the device.
* Host tools: `mkbootimg-osm0sis` and `unpackbootimg` (osm0sis Android
  boot tools), `zstd`, `cpio`, `sha256sum`, `dd`.
* A backup of the boot partition you are about to write. Without it, stop.

## 1. Build the kernel

Build with the in-tree defconfig for the platform:

```sh
git clone https://github.com/omnipha/linux-qualcomm-sm8250
cd linux-qualcomm-sm8250
make O=out ARCH=arm64 LLVM=1 omnipha_sm8250_defconfig
make O=out ARCH=arm64 LLVM=1 -j$(nproc)
```

Inputs of the measured image (release `7.2.0-g6c71d80b5a83`, commit
`6c71d80b5a83`): `out/arch/arm64/boot/Image.gz`,
`out/arch/arm64/boot/dts/qcom/sm8250-oneplus-instantnoodlep.dtb`, and
`out/lib/modules` for module install. The compiler was Alpine clang 23.1.x. Other
toolchains are untested.

Install the modules into a staging directory; they must end up under
`/lib/modules/<release>` on the device root filesystem:

```sh
make O=out ARCH=arm64 LLVM=1 \
     INSTALL_MOD_PATH=<staging> modules_install
```

Then copy `<staging>/lib/modules/<release>` to
`/lib/modules/<release>` on the device (or into the root filesystem
image), followed by `depmod <release>` on the device.

## 2. Initramfs: reuse the stock ramdisk, swap the module directory

The measured boot images do not contain a self-built initramfs. The
ramdisk is the one from the running `boot_b` (backup taken before the
flash). Measured with `diff -rq` between the unpacked old ramdisk
(release `7.2.0-g1a8787818fe1`) and the new one (`7.2.0-g6c71d80b5a83`):
the only differences are the module directories
`lib/modules/<release>` and `usr/lib/modules/<release>` (the old release
directory replaced by the new one). Init scripts, `libz` (1.3.2) and all
other files are identical. The new ramdisk holds 14 `.ko.zst` modules
(`evdev`, the USB gadget set `libcomposite`/`u_ether`/`u_serial`/
`usb_f_acm`/`usb_f_mass_storage`/`usb_f_ncm`/`usb_f_rndis`,
`usb-storage`, `btrfs`, `f2fs`, `xfs`, `raid6_pq`, `xor`). Without the
gadget modules of the matching release there is no USB networking in
early boot (Wi-Fi still comes up).

```sh
# 1. Backup the current boot partition (on the device), then verify:
dd if=/dev/disk/by-partlabel/boot_b of=boot_b-backup.img bs=4M
sha256sum boot_b-backup.img

# 2. Unpack the backup on the host (writes <prefix>-ramdisk, -cmdline, ...):
mkdir u && unpackbootimg -i boot_b-backup.img -o u/boot_b

# 3. Extract the ramdisk (zstd compressed in the measured image):
mkdir rd && cd rd
zstd -dc ../u/boot_b-ramdisk | cpio -idm

# 4. Swap the module directory for the new release, in both places:
rm -rf lib/modules/<old-release> usr/lib/modules/<old-release>
# copy the 14 modules (as .ko.zst, from <staging>/lib/modules/<new-release>)
# to usr/lib/modules/<new-release>/kernel/... with the same relative paths
# as the old release, and its modules.* files (depmod output); keep the
# lib/modules link layout of the old ramdisk.

# 5. Re-pack:
find . | cpio -o -H newc | zstd -19 -T0 -o ../initramfs-<new-release>.zst
```

Step 4 and 5 are the documented intent; the measured
`initramfs-deferred-mhi.zst` was produced this way, but the exact
pack options (zstd level, cpio ordering) were not recorded, so a repack
is not byte-identical. Only the final `boot-candidate.img` pack step
below is byte-reproducible from its inputs.

The ramdisk contains device specific init scripts of this unit's
postmarketOS install; keep it local and do not publish it.

## 3. Pack the boot image

This exact command reproduces the measured `boot-candidate.img`
(byte-identical, verified with `cmp`, SHA-256
`ea2551bbc7fe9a74b021ba83cedfed65fa71f17edda5f9b12345632fd73486a1`):

```sh
mkbootimg-osm0sis \
    --kernel Image.gz \
    --ramdisk initramfs-<new-release>.zst \
    --dtb sm8250-oneplus-instantnoodlep.dtb \
    --cmdline "console=tty0 fbcon=nodefer ignore_loglevel clk_ignore_unused pd_ignore_unused pmos_boot_uuid=0780d7f9-0c66-41a2-8975-ad58dbee86bd pmos_root_uuid=6034d544-5ed8-4581-a799-4be7c9e638b9 pmos_rootfsopts=defaults" \
    --base 0x00000000 --kernel_offset 0x00008000 \
    --ramdisk_offset 0x01000000 --second_offset 0x00000000 \
    --tags_offset 0x00000100 --dtb_offset 0x01f00000 \
    --pagesize 4096 --header_version 2 --hashtype sha1 \
    -o boot-candidate.img
```

`pmos_boot_uuid` and `pmos_root_uuid` select the boot and root
filesystems of this one install. Another install needs its own values:
read them from `u/boot_b-cmdline` of the working image (unpacked in
step 2 above) and reuse the other parameters as they are. The layout
parameters were taken from that unpacked image and are measured on this
unit only.

Modules are not inside the image; install `/lib/modules/<release>` on the
rootfs before rebooting, or USB networking in early boot and later module
autoload will fail.

## 4. Flash and verify

On the device (root), with `boot-candidate.img` copied over:

```sh
# Backup first (already done in step 2; repeat if unsure):
dd if=/dev/disk/by-partlabel/boot_b of=boot_b-backup.img bs=4M

# Write:
dd if=boot-candidate.img of=/dev/disk/by-partlabel/boot_b bs=4M conv=fsync

# Read back and compare hashes:
dd if=/dev/disk/by-partlabel/boot_b bs=4M count=11 | sha256sum
sha256sum boot-candidate.img
```

The active slot (`_b` here, device node `sde35` on the measured unit) is
the measured target; the same procedure applies to `boot_a` as the
fallback slot. After the write, reboot once. On the measured unit the
boot image is 43515904 bytes, so the read-back must cover at least that
many bytes (11 x 4 MiB). If the image does not boot, reflash the backup of step 2 to the slot
via fastboot (`fastboot flash boot_b boot_b-backup.img`, or switch slot
with `fastboot --set-active=a`).

Reference log of the measured flash (local only, not in this repo):
`/home/user/mb005-build/boot-tests/bootb-flash-20261124.log`.

## 5. Modem firmware staging (per kernel release)

The flashless SDX55M needs its firmware staged under the release-specific
path, see [sdx55-stage.sh](sdx55-stage.sh) and
[modem-userspace/README.md](modem-userspace/README.md). After a kernel
release change: run `sdx55-stage.sh stage` on the device, then reboot
once. Without staging, the modem stays offline.

## Known-good values (measured)

| Item | Value |
| --- | --- |
| Kernel release | `7.2.0-g6c71d80b5a83` |
| Image size | 43515904 bytes |
| Image SHA-256 | `ea2551bbc7fe9a74b021ba83cedfed65fa71f17edda5f9b12345632fd73486a1` |
| Ramdisk | stock `boot_b` ramdisk, module directory swapped, 14 modules |
| Slot | `_b` (device node `sde35`) |
| Result | boots, WLAN/SSH up, modem Mission Mode, IPv4 data via `qmapmux0.0` |
