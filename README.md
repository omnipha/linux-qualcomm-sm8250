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

## Devices in the base tree

The imported kernel contains device trees for several SM8250 devices, including OnePlus, Samsung, Sony, Xiaomi and Lenovo models. A device tree does not by itself prove working hardware support.

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
