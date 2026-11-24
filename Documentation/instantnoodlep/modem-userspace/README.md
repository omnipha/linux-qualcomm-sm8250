# SDX55M userspace (OnePlus 8 Pro)

State: **incomplete**. The modem reaches Mission Mode and ModemManager sees its
ports, but the modem cannot be enabled yet (QMI error 52, `DeviceNotReady`). See
[../STATUS.md](../STATUS.md) for the measured state. Measured on one unit only,
kernel `7.2.0-g1a8787818fe1`, postmarketOS (Alpine, systemd).

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

- Enabling the modem fails with `DeviceNotReady`. The cause is not found.
- UIM reports the USIM in slot 1, but the primary provisioning session stays
  empty and ModemManager selects slot 2. Switching the slot fails (QMI error 3).
- Registration, data, SMS, calls, IMS and GNSS are untested.
- Keep EFS, modem firmware, calibration data and SIM identifiers out of logs and
  issues.
