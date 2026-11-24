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

## Measured on kernel `7.2.0-g1a8787818fe1` (2026-11-24)

Same unit (OnePlus 8 Pro IN2023), commit [1a8787818fe1](https://github.com/omnipha/linux-qualcomm-sm8250/commit/1a8787818fe1), cold boot from `boot_b` (no kexec), postmarketOS-based root filesystem. Only what was observed on this boot is listed; the table above was not re-measured.

| Component | Observed status |
| --- | --- |
| Boot | Cold boot from `boot_b`, WLAN (`wlan0`) up, stable for the observation window. |
| Remote processors | `adsp`, `cdsp`, `slpi` running. |
| Thermal | 29 thermal zones; cooling devices include `devfreq-3d00000.gpu` (fix for #1 is active in this build). |
| Task I/O accounting | `/proc/self/io` is readable (fix for #2 is active in this build). |
| SDX55M modem, kernel level | `mhi0` reached **Mission Mode** at 18:30:17 (PBL, SBL, Sahara, Mission Mode). MHI devices DIAG, EFS, MBIM, QMI, IPCR, IP_SW0, IP_HW0 exist. `wwan0` with `wwan0mbim0`, `wwan0qmi0`, `wwan0qcdm0` is present; `mhi_hwip0` and `mhi_swip0` exist. The previous kernel `398cbb77` stayed in SBL with the same inputs. |
| SDX55M modem, userspace | `sdx55-rfsd` serves the modem EFS requests (reads, writes and EFS syncs observed). With the patched ModemManager the ports `mhi_hwip0 (net)` and `qrtr3 (qmi)` are detected; before, ModemManager reported `Failed to find net port`. |
| SIM | QMI UIM reports a card with a USIM application in slot 1 and a card error in slot 2 (no ATR, no card inserted). The SIM is known to work in another system and has no PIN. |

**Modem result after matching the firmware (2026-11-24 21:12, boot ID `6d121e55`, same kernel `7.2.0-g1a8787818fe1`):** with the 17 loader images staged from the booted slot's modem partition (`sdx55-stage.sh stage`, installed set untouched, no partition written) and one reboot, the modem went online without any other change. DMS operating mode `online`; ModemManager state `registered`, registration `home`, packet service `attached`, access technologies LTE and 5G NR, signal quality 76 to 81 percent, SIM in slot 1 with PIN disabled. Before the staging, 8 of 13 installed boot images differed from the slot's modem partition and the modem stayed `offline` with QMI error 52 (`DeviceNotReady`). The staged set is still in place; the installed firmware set was not repaired.

**Not measured yet:** mobile data (no bearer connected, `mhi_hwip0` still down), SMS, calls, IMS, GNSS, behavior over time and across further reboots. The Sahara driver logs one DL callback error `-107` shortly after Mission Mode; its meaning is unknown. This is one unit and one boot.

The userspace side is described in [modem-userspace/README.md](modem-userspace/README.md).

## Known open issues

- GPU devfreq thermal cooling was disabled in the kernel config; a source fix (`CONFIG_DEVFREQ_THERMAL=y`) was merged in `8cd047b96e1e` on 2026-11-21 and [#1](https://github.com/omnipha/linux-qualcomm-sm8250/issues/1) is closed; on-device verification still requires flashing the new kernel.
- Per-task I/O accounting was disabled in the kernel config, so `/proc/self/io` was unavailable; a source fix (`CONFIG_TASKSTATS=y`, `CONFIG_TASK_XACCT=y`, `CONFIG_TASK_IO_ACCOUNTING=y`) was merged in `9763e16ad036` on 2026-11-21 and [#2](https://github.com/omnipha/linux-qualcomm-sm8250/issues/2) is closed; on-device verification still requires flashing the new kernel.
- The RTC cannot store time on this kernel; `hwclock --systohc` fails with `ENODEV`. A source fix (PM8150 SDAM2 offset cell, `CONFIG_NVMEM_SPMI_SDAM=y`) was merged in `7e5c7b1ce280` on 2026-11-20 and [#3](https://github.com/omnipha/linux-qualcomm-sm8250/issues/3) is closed; on-device verification still requires flashing the new DTB.
- The SDX55M modem reaches Mission Mode and registers on the home network on this unit with `1a8787818fe1` plus a matched firmware set (see above). [#4](https://github.com/omnipha/linux-qualcomm-sm8250/issues/4) stays **open**: data, stability and reproducibility on a clean install are not measured. GNSS is tracked in [#11](https://github.com/omnipha/linux-qualcomm-sm8250/issues/11).

## Not verified

- Sensors (accelerometer, gyroscope, magnetometer, light, proximity) do not work.
- Camera hardware (IMX689, IMX586, IMX471, S5K3M5, GC5035 and focus actuators) is present in the device tree and its drivers are built, but capture, camera GUI and image quality are not verified; a device tree and a compiled driver are not proof of a working camera.
- Suspend/resume, mobile data, SMS, calls, NFC and GPS are unverified.
