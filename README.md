# Linux on Qualcomm SM8250

Mainline-based Linux kernel tree for devices using the Qualcomm Snapdragon 865 platform (`SM8250`, including 865+ and 870). The first measured target is the OnePlus 8 Pro (`instantnoodlep`).

This is a kernel source tree, not a bootable image and not an installer.

## Source

- Upstream: [postmarketOS SM8250 kernel](https://gitlab.postmarketos.org/soc/qualcomm-sm8250/linux)
- Base tag: `sm8250-7.2.0_git20261010`
- Base commit: `3c5440e9dd3c3e3b5735ad8f1b22bdfd02c707d9`
- Linux version: 7.2.0
- Branch `omnipha`: base plus the measured OnePlus 8 Pro source changes

The GitLab URL currently redirects to `gitlab.nura.eco`.

## Devices

The table lists every device tree in this tree, using the real `model` property of each source file. A device tree does not by itself prove working hardware support. "Device tree present" means Omnipha has not tested that device; only one OnePlus 8 Pro has been measured ([status](Documentation/instantnoodlep/STATUS.md)).

| Device | Codename | Status |
|---|---|---|
| OnePlus 8 Pro (`instantnoodlep`) | `instantnoodlep` | Boots with a custom setup; partial measured support |
| OnePlus 8T (`kebab`) | `kebab` | Device tree present; not tested by Omnipha |
| Lenovo Xiaoxin Pad Pro 12.6 (`q706f`) | `q706f` | Device tree present; not tested by Omnipha |
| Samsung Galaxy S20 (`x1q`) | `x1q` | Device tree present; not tested by Omnipha |
| Samsung Galaxy S20 FE (`r8q`) | `r8q` | Device tree present; not tested by Omnipha |
| Sony Xperia 1 II (`pdx203`) | `pdx203` | Device tree present; not tested by Omnipha |
| Sony Xperia 5 II (`pdx206`) | `pdx206` | Device tree present; not tested by Omnipha |
| Xiaomi Mi Pad 5 Pro, BOE and CSOT panels (`elish`) | `elish` | Device tree present; not tested by Omnipha |
| Xiaomi Mi Pad 5 Pro 5G (`enuma`) | `enuma` | Device tree present; not tested by Omnipha |
| Xiaomi Pad 6, CSOT and Tianma panels (`pipa`) | `pipa` | Device tree present; not tested by Omnipha |
| Qualcomm SM8250 HDK (`sm8250-hdk`) | `sm8250-hdk` | Device tree present; not tested by Omnipha |
| Qualcomm SM8250 MTP (`sm8250-mtp`) | `sm8250-mtp` | Device tree present; not tested by Omnipha |

Measurements apply only to the single device they were recorded on. See the [measured OnePlus 8 Pro status](Documentation/instantnoodlep/STATUS.md) and the repository rules in [AGENTS.md](AGENTS.md).

## Measured on one OnePlus 8 Pro

The changes on `omnipha` come from the recorded source patches in [omnipha/linux-sm8250](https://github.com/omnipha/linux-sm8250):

| Area | In this tree | Verification |
|---|---|---|
| Display panel | Samsung AMS678UW01 bindings, driver and device tree | Source integrated; combined boot from this tree not yet tested |
| Audio | WCD9385 and MI2S device-tree wiring | Source integrated; boot from this tree not yet tested |
| Cameras | IMX689, IMX586, IMX471, S5K3M5, GC5035, focus actuators and CAMSS changes | Source integrated; boot from this tree not yet tested |
| GPU and fastboot | GPU enabled with measured firmware name and power-on modes | Device tree compiled; boot from this tree not yet tested |

The device tree `sm8250-oneplus-instantnoodlep.dtb` was compiled from this branch with `ARCH=arm64 LLVM=1` on 2026-11-14. The full kernel image and modules have not yet been built or booted from this repository.

Firmware blobs are not included. The GPU entry only names `qcom/sm8250/OnePlus/instantnoodlep/a650_zap.mbn`.

## Build the device tree

```sh
git clone --branch omnipha https://github.com/omnipha/linux-qualcomm-sm8250.git
cd linux-qualcomm-sm8250
make O=out ARCH=arm64 LLVM=1 omnipha_sm8250_defconfig
make O=out ARCH=arm64 LLVM=1 dtbs
```

Output: `out/arch/arm64/boot/dts/qcom/sm8250-oneplus-instantnoodlep.dtb`.

The configuration starts from the pinned postmarketOS SM8250 configuration. It builds the OnePlus panel driver into the kernel and enables the camera sensor and focus drivers as modules. A complete kernel build is:

```sh
make -j"$(nproc)" O=out ARCH=arm64 LLVM=1 Image modules dtbs
```

That full build has not yet been run from this repository. Clang, LLD, LLVM, flex, bison, bc, OpenSSL, pahole and Python are required.

Do not flash the result without a verified backup and recovery path. This repository does not provide an installer.
