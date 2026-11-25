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

## Known state and limits

- Run `sdx55-stage.sh stage` (see `../sdx55-stage.sh`) before the boot, so the 17 loader images come from the modem partition of the booted slot. Without it the modem stayed offline.
- ModemManager still lists slot 2 as primary slot; the UIM primary session is slot 1 and registration works.
- The staging path is release specific (`/lib/firmware/updates/<kernel release>/qcom/sdx55m`). Re-run `sdx55-stage.sh stage` for every new kernel release and reboot once afterwards.
- `rmnet` must be loaded (`modprobe rmnet`); autoload is not configured yet.
- Mobile data, reproduced steps on the test unit: `nmcli connection add type gsm ifname '*' con-name mobile-o2 gsm.apn internet connection.autoconnect no ipv4.route-metric 900 ipv6.route-metric 900`, then `nmcli connection up mobile-o2 ifname qrtr3`. ModemManager creates `qmapmux0.0` (multiplexed). WLAN keeps the default route (metric 600), cellular is the second default route (metric 900). Verified with `ping -I qmapmux0.0 1.1.1.1` and `curl --interface qmapmux0.0 https://example.com` (HTTP 200).
- Do not use `mmcli --simple-connect ... multiplex=none`: the bearer lands on `mhi_hwip0` and drops all packets (100 percent loss).
- IPv6 over cellular, data across reboots, SMS, calls, IMS and GNSS are untested.
- Keep EFS, modem firmware, calibration data and SIM identifiers out of logs and
  issues.
