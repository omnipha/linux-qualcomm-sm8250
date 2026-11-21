# Measured hardware status (OnePlus 8 Pro)

Everything below was measured on **one OnePlus 8 Pro IN2023 (`instantnoodlep`)** on 2026-11-20, running kernel `7.2.0-gb56ee7a86da4` from commit [b56ee7a86da4](https://github.com/omnipha/linux-qualcomm-sm8250/commit/b56ee7a86da4) on this `omnipha` branch, with a postmarketOS-based root filesystem. The results apply only to this unit and this kernel; they do not establish support for other devices, other hardware revisions, or later commits.

## Verified on the test device

| Component | Observed status |
| --- | --- |
| Boot and storage | The kernel boots and mounts the ext4 root filesystem with the custom boot setup. |
| Display | The native panel works at 1440x3168 at 120 Hz. |
| Touch | The `s6sy761` touchscreen works. |
| GPU | The Adreno 650 works with freedreno (mesa), using firmware `a650_zap.mbn`. |
| Wi-Fi | The QCA6390 works with `ath11k`. |
| Bluetooth | The QCA6390 Bluetooth controller works. |
| Audio | The OnePlus 8 Pro sound card with WCD9385 codec works. |
| Battery and charging | The `bq27411` fuel gauge and the `pm8150b-charger` driver report battery data. |
| USB | USB gadget networking (`usb0`) works. |
| Remote processors | `adsp`, `cdsp` and `slpi` are loaded and running. |
| Thermal and cpufreq | 29 thermal zones are exposed; `qcom-cpufreq-hw` controls CPU frequency scaling. |
| Panic log | `ramoops` is active and records kernel oopses across reboots. |

## Known open issues

- GPU devfreq thermal cooling is not enabled: [#1](https://github.com/omnipha/linux-qualcomm-sm8250/issues/1).
- Per-task I/O accounting is disabled, so `/proc/self/io` is unavailable: [#2](https://github.com/omnipha/linux-qualcomm-sm8250/issues/2).
- The RTC cannot store time on this kernel; `hwclock --systohc` fails with `ENODEV`. A source fix (PM8150 SDAM2 offset cell, `CONFIG_NVMEM_SPMI_SDAM=y`) was merged in `7e5c7b1ce280` on 2026-11-20 and [#3](https://github.com/omnipha/linux-qualcomm-sm8250/issues/3) is closed; on-device verification still requires flashing the new DTB.
- The SDX55M modem on PCIe (`17cb:0306` / `17cb:010c`) does not boot; no SBL firmware for subsystem `17cb:010c`, WWAN disabled: [#4](https://github.com/omnipha/linux-qualcomm-sm8250/issues/4).

## Not verified

- Sensors (accelerometer, gyroscope, magnetometer, light, proximity) do not work.
- Camera hardware (IMX689, IMX586, IMX471, S5K3M5, GC5035 and focus actuators) is present in the device tree and its drivers are built, but capture, camera GUI and image quality are not verified; a device tree and a compiled driver are not proof of a working camera.
- Suspend/resume, mobile network, NFC and GPS are unverified.
