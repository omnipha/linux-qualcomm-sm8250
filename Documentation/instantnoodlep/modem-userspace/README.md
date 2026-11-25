# SDX55M userspace (OnePlus 8 Pro)

State: **registration and IPv4 mobile data work on one unit**. With a firmware set matched to the booted slot the modem goes online and registers (LTE/5G NR); with the generic installed set it stayed offline (QMI error 52, `DeviceNotReady`). Data needs `CONFIG_RMNET=m` (kernel `6c71d80b5a83` or later). See
[../STATUS.md](../STATUS.md) for the measured state. Measured on one unit only,
kernel `7.2.0-g6c71d80b5a83`, postmarketOS (Alpine, systemd), 2026-11-25.

The kernel provides MHI, Sahara, QRTR and WWAN. The modem additionally needs
userspace helpers that serve its file system requests and provision the SIM.
Those helpers are not part of this repository: they come from the
[Nura reference port](https://github.com/darknagel/oneplus-instantnoodlep-nura-unofficial),
`modem/` directory, **pinned to commit `c15014dc571947d0bfec251fcba59bf006f880b4`** (the `modem/` directory is byte-identical at the later local commit `2b25a23`, which is not published).
The reference repository carries no license file, so its scripts are not copied
here. Follow its [modem README](https://github.com/darknagel/oneplus-instantnoodlep-nura-unofficial/blob/c15014dc571947d0bfec251fcba59bf006f880b4/modem/README.md)
and `modem/install.sh` at that commit.

What was installed on the test unit from that revision:

| Part | Installed as | Purpose |
| --- | --- | --- |
| `rfsd.py` | `/usr/local/bin/sdx55-rfsd`, `sdx55-rfsd.service` | answers the modem's remote file system requests over QRTR |
| `efssave.py` | `/usr/local/bin/sdx55-efssave`, udev rule `79-sdx55-efssave.rules` | stores the EFS on devcoredump events |
| `sdx55-sim.py` | `/usr/local/bin/sdx55-sim`, `sdx55-sim.service` | loads `mhi_net`, starts ModemManager, provisions a present USIM |
| `modemstate.py` | `/usr/local/bin/sdx55-modemstate` | sets the modem online/offline over QMI DMS |
| `sdx55-gnss.py` | `/usr/local/bin/sdx55-gnss`, `sdx55-gnss.service` | clean-room QMI LOC client over QRTR, streams NMEA to `/dev/gnss-sdx55` for gpsd |
| rules and conf | `78-mm-sdx55-qrtr.rules`, `sdx55-mhi-net.conf`, ModemManager drop-in | port tagging, module load, MM settings |

## Patched ModemManager

Stock Alpine ModemManager does not handle the SDX55 on MHI/QRTR (`Failed to find
net port`). [modemmanager/](modemmanager/) holds the APKBUILD and the patches
used for the test build (`1.25.95_git20261005-r7`, upstream commit `7f0bf17ab518`).
Patches 0003 to 0006 add the `mhi_net` data port, multiplexing by default, the
bearer handling and the WDS event change; they originate from the reference
port's ModemManager patches. Build on the device:

```sh
apk add alpine-sdk
abuild-keygen -a -n
cd Documentation/instantnoodlep/modem-userspace/modemmanager
abuild -F -d -r    # needs the -dev makedepends from the APKBUILD
apk add --allow-untrusted ~/packages/*/aarch64/{libmm-glib,modemmanager,modemmanager-systemd,modemmanager-udev}-1.25.95_git20261005-r7.apk
```

On the test unit `elogind-dev` had to be dropped from `makedepends` because it
conflicts with the systemd on the device, and `systemd-dev` was installed
instead of `eudev`. The result is a locally signed package, installed with
`--allow-untrusted`. This was done once; the build is not yet reproduced by a
second person.

## SDX55 GNSS (QMI LOC via QRTR)

GNSS is implemented through a clean-room Python client, `sdx55-gnss.py`, that connects directly to the SDX55 modem's Location service (QMI LOC, service ID 16) over QRTR (`AF_QIPCRTR`).

Key protocol and architecture details:
- **Transport & Discovery:** Uses QRTR lookup (`QRTR_TYPE_NEW_LOOKUP = 10` on `QRTR_PORT_CTRL = 0xfffffffe`) to dynamically discover the LOC service (found at node 3, port 93, instance 2).
- **Service Configuration:**
  - Client revision: negotiated to 2 (`QMI_LOC_SERVICE_CLIENT_REVISION`, 0x0020).
  - Engine lock: set to unlocked / none (`QMI_LOC_SET_ENGINE_LOCK`, 0x003a).
  - NMEA sentences: enabled standard sentence types (`QMI_LOC_SET_NMEA_TYPES`, 0x003e, mask `0x39f` for GGA, RMC, GSV, GSA, VTG, GLGSV, GNGSA, GNGNS).
  - Time injection: current UTC wall-clock time injected on start (`QMI_LOC_INJECT_UTC_TIME`, 0x0038).
  - Positioning mode: standalone GNSS (`QMI_LOC_SET_OPERATION_MODE`, 0x004a, mode 4).
  - Event registration: registered for NMEA indications (`QMI_LOC_REGISTER_EVENTS`, 0x0021, flag `0x04`).
- **Session Lifecycle:** Continuous tracking started with 1 Hz fix interval (`QMI_LOC_START`, 0x0022). On SIGINT or SIGTERM, the client cleanly stops tracking (`QMI_LOC_STOP`, 0x0023), removes the pseudo-terminal symlink, and exits.
- **Pseudo-Terminal (PTY) Bridge:** Creates a pseudo-terminal pair in raw mode (permissions 0666) with a symlink at `/dev/gnss-sdx55` for standard GNSS daemons like `gpsd`.
- **Self-Test Option:** `python3 sdx55-gnss.py --test [seconds]` runs a standalone verification test checking discovery, session start, NMEA stream capture, fix inspection, and session stop.
- **Integration with gpsd:** Verified with `gpsd 3.27.3-r1` (`gpsd -N -D 2 -S 2947 /dev/gnss-sdx55`). `gpsd` auto-detects driver `NMEA0183` and serves sentences via `gpspipe -r` (raw NMEA) and `gpspipe -w` (JSON TPV/SKY reports).
- **Systemd Units:** On the device, the client runs under `sdx55-gnss.service` with `sdx55-gnss-sleep.service` ensuring tracking is stopped before system sleep (units stored in `phone-second-life` under `devices/mb005/modem/device-installed/`).

## Known state and limits

- Run `sdx55-stage.sh stage` (see `../sdx55-stage.sh`) before the boot, so the 17 loader images come from the modem partition of the booted slot. Without it the modem stayed offline.
- ModemManager still lists slot 2 as primary slot; the UIM primary session is slot 1 and registration works.
- The staging path is release specific (`/lib/firmware/updates/<kernel release>/qcom/sdx55m`). Re-run `sdx55-stage.sh stage` for every new kernel release and reboot once afterwards.
- `rmnet` must be loaded (`modprobe rmnet`); autoload is not configured yet.
- Mobile data, reproduced steps on the test unit: `nmcli connection add type gsm ifname '*' con-name mobile-o2 gsm.apn internet connection.autoconnect no ipv4.route-metric 900 ipv6.route-metric 900`, then `nmcli connection up mobile-o2 ifname qrtr3`. ModemManager creates `qmapmux0.0` (multiplexed). WLAN keeps the default route (metric 600), cellular is the second default route (metric 900). Verified with `ping -I qmapmux0.0 1.1.1.1` and `curl --interface qmapmux0.0 https://example.com` (HTTP 200).
- Do not use `mmcli --simple-connect ... multiplex=none`: the bearer lands on `mhi_hwip0` and drops all packets (100 percent loss).
- GNSS: QMI LOC service discovery, session start/stop, NMEA streaming via `/dev/gnss-sdx55`, and gpsd integration verified on one unit indoors ("No fix, indoor"). Outdoor fix and suspend/resume lifecycle remain open (#11).
- IPv6 over cellular, data across reboots, SMS, calls, and IMS are untested.
- Keep EFS, modem firmware, calibration data and SIM identifiers out of logs and
  issues.
