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

**Mobile data (2026-11-25, kernel `7.2.0-g6c71d80b5a83`, boot ID `fef93284`):** `6c71d80b5a83` sets `CONFIG_RMNET=m` (commit `arm64: defconfig: enable RMNET for SDX55 MHI data`). The firmware staging is release specific, so it was re-created for the new release (`sdx55-stage.sh stage`) and one reboot followed. Result: ModemManager `registered`, `home`, LTE and 5G NR, signal quality 81, packet service `attached`. `rmnet` was loaded by hand (`modprobe rmnet`); no autoload is configured yet. Data path: NetworkManager profile `mobile-o2` (gsm, APN `internet`, `autoconnect no`, route metric 900) activated with `nmcli connection up mobile-o2 ifname qrtr3`. ModemManager creates `qmapmux0.0` with an IPv4 /30 and a second default route (metric 900); WLAN keeps metric 600. Measured over `qmapmux0.0` only: `ping -I qmapmux0.0 1.1.1.1` 3/3 received (34 to 54 ms), `curl --interface qmapmux0.0 https://example.com` HTTP 200. A first attempt with `mmcli --simple-connect` and `multiplex=none` created a bearer on `mhi_hwip0`, but 100 percent packet loss: use the multiplexed `qmapmux0.0` path.

**Resume failure from M3 (2026-11-25, boot ID `fef93284`, kernel `7.2.0-g6c71d80b5a83`):** 1110 clean runtime-PM cycles (M3 and back to M0, about 315 per hour) from 08:15, then one failure at 11:46:10: `Did not enter M0 state`, `failed to resume device: -5`, `device recovery started`. The PCIe secondary bus reset failed (`retraining failed`, `Data Link Layer Link Active not set`, `Recovery failed: -25`), all MHI devices were removed and ModemManager found no modem until the next reboot at 13:20 (94 minutes). No `firmware crashed` message was logged, so a modem firmware crash is not indicated; the cause of the link loss is not determined. Earlier boots on the same unit: 157 and 1251 cycles, no failure (about 2500 cycles, one failure in total). The driver sets `power/control=on` on the device in `mhi_pci_recovery_work` after a failed recovery. Workaround in use since 13:20: runtime PM locked to `on` for `0002:01:00.0` (modem stays in M0, higher idle power). With the lock: 0 failures, modem registered and data working, observed for about 90 minutes on one boot only; this is not proof of stability.

**GNSS via ModemManager & QMI LOC over QRTR (2026-11-25, boot ID `38de5725`, kernel `7.2.0-g6c71d80b5a83`, commit `6c71d80b5a83`):**
1. *ModemManager standard path:* ModemManager 1.25.95 natively drives the SDX55 Location engine over QRTR through its `qcom-soc` plugin (`qrtr3`). Reported capabilities: `3gpp-lac-ci, gps-raw, gps-nmea, agps-msa, agps-msb`, SUPL `supl.google.com:7275`, XTRA assistance supported. Enabling via `mmcli -m 0 --location-enable-gps-nmea --location-enable-gps-raw` succeeded immediately; refresh rate configurable (tested at 1s). Standard NMEA 0183 sentences ($GPGSA, $GNGNS, $GPRMC, $GNGSA, $GPGSV, $GLGSV, $GPVTG, $GPGGA) were continuously received and exposed on D-Bus (`org.freedesktop.ModemManager1.Modem.Location`, queryable with `mmcli -m 0 --location-get`). Fix status indoors: "No fix, indoor" (fix quality 0 / mode 1 / status 'V', satellites visible in GSV, exactly 0 fixes). Consumers: GeoClue (`geoclue`) consumes location natively from ModemManager over D-Bus (`[modem-gps]` source). State was restored after testing (`mmcli -m 0 --location-enable-3gpp --location-disable-agps-msb --location-set-disable-signal`, refresh rate 0; baseline `enabled: 3gpp-lac-ci`, `signals: no`, GPS engine off).
2. *gpsd & fallback PTY client:* Because the SDX55 on MHI/QRTR exposes no character device node (`/dev/tty*`), ModemManager publishes location exclusively over D-Bus; `gpsd` does not have a D-Bus client backend and requires a character device. The clean-room userspace client `sdx55-gnss.py` serves as a fallback: it connects to QMI LOC on node 3, port 93 and exposes NMEA through pseudo-terminal `/dev/gnss-sdx55` (mode 0666; exists only while the client process runs), successfully verified with `gpsd 3.27.3-r1` (`gpspipe -r` and `gpspipe -w`; `gpsd` inactive, fallback units disabled by default). Mobile data (`qmapmux0.0`) remained fully functional throughout. Outdoor fix and suspend/resume lifecycle remain open ([#11](https://github.com/omnipha/linux-qualcomm-sm8250/issues/11)).

**Not measured yet:** IPv6 over cellular, data across reboots without manual steps (`rmnet` is not autoloaded and the NetworkManager profile has `autoconnect no`), SMS, calls, IMS, outdoor GNSS fix and suspend/resume lifecycle ([#11](https://github.com/omnipha/linux-qualcomm-sm8250/issues/11)), 5G NR data (LTE only observed in the last session). The Sahara driver logs one DL callback error `-107` shortly after Mission Mode; its meaning is unknown. This is one unit.

The userspace side is described in [modem-userspace/README.md](modem-userspace/README.md).

## Known open issues

- GPU devfreq thermal cooling was disabled in the kernel config; a source fix (`CONFIG_DEVFREQ_THERMAL=y`) was merged in `8cd047b96e1e` on 2026-11-21 and [#1](https://github.com/omnipha/linux-qualcomm-sm8250/issues/1) is closed; on-device verification still requires flashing the new kernel.
- Per-task I/O accounting was disabled in the kernel config, so `/proc/self/io` was unavailable; a source fix (`CONFIG_TASKSTATS=y`, `CONFIG_TASK_XACCT=y`, `CONFIG_TASK_IO_ACCOUNTING=y`) was merged in `9763e16ad036` on 2026-11-21 and [#2](https://github.com/omnipha/linux-qualcomm-sm8250/issues/2) is closed; on-device verification still requires flashing the new kernel.
- The RTC cannot store time on this kernel; `hwclock --systohc` fails with `ENODEV`. A source fix (PM8150 SDAM2 offset cell, `CONFIG_NVMEM_SPMI_SDAM=y`) was merged in `7e5c7b1ce280` on 2026-11-20 and [#3](https://github.com/omnipha/linux-qualcomm-sm8250/issues/3) is closed; on-device verification still requires flashing the new DTB.
- The SDX55M modem reaches Mission Mode and registers on the home network on this unit with `1a8787818fe1` plus a matched firmware set (see above). IPv4 mobile data works on this unit with `6c71d80b5a83` (see above). [#4](https://github.com/omnipha/linux-qualcomm-sm8250/issues/4) is closed: Mission Mode, WWAN ports, registration and IPv4 data are measured on this unit; the resume failure above is documented, any new modem problem gets a new issue. GNSS is tracked in [#11](https://github.com/omnipha/linux-qualcomm-sm8250/issues/11) (userspace QMI LOC client `sdx55-gnss.py` verified with NMEA and gpsd indoors; outdoor fix and suspend/resume remain open).

## Not verified

- Sensors (accelerometer, gyroscope, magnetometer, light, proximity) do not work.
- Camera hardware (IMX689, IMX586, IMX471, S5K3M5, GC5035 and focus actuators) is present in the device tree and its drivers are built, but capture, camera GUI and image quality are not verified; a device tree and a compiled driver are not proof of a working camera.
- Suspend/resume, SMS, calls and NFC are unverified. Mobile data is verified for IPv4 on one unit only. GNSS has indoor NMEA reception verified, but no outdoor fix.
