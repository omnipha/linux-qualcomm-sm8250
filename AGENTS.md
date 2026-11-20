# AGENTS.md — linux-qualcomm-sm8250

Kernel source tree for the Qualcomm Snapdragon 865 platform (`SM8250`, including 865+ and 870). Measured target: OnePlus 8 Pro (`instantnoodlep`), see [Documentation/instantnoodlep/STATUS.md](Documentation/instantnoodlep/STATUS.md). This is source, not a bootable image.

## Source policy

- Changes that apply to all SM8250 devices belong in shared files: `arch/arm64/boot/dts/qcom/sm8250.dtsi`, the shared defconfig `arch/arm64/configs/omnipha_sm8250_defconfig`, and shared drivers.
- Device-specific device-tree wiring belongs only in the device or device-family device tree, e.g. `arch/arm64/boot/dts/qcom/sm8250-oneplus-common.dtsi`.
- Never move device-specific SDAM pin, GPIO or firmware choices into SoC-wide files.
- Check upstream precedent first: if upstream Linux keeps something device-specific in the device DT or family DT, keep it there here too.

## Reporting results

- Claim measurements only for the exact device and unit they were measured on, and state model, kernel version, commit and date. Never present untested hardware as working.

## Device access

- No flashing and no reboot without an approved recovery path.

## Contributing

- Follow the organization-wide [CONTRIBUTING](https://github.com/omnipha/.github/blob/main/CONTRIBUTING.md).
- Sign commits (`git commit -s`), English commit messages.
- Never commit or log secrets.
