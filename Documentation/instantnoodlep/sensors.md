# Snapdragon Sensor Core (SSC) on OnePlus 8 Pro (instantnoodlep)

## Architecture Overview

Sensors on the Qualcomm Snapdragon 865 (`SM8250`) platform on the OnePlus 8 Pro (`instantnoodlep`) are managed by the Snapdragon Sensor Core (SSC) running on the Sensors Low-Power Island (SLPI) Hexagon DSP (`remoteproc0`).

Rather than registering individual sensors as direct Linux kernel I2C/SPI client devices, sensor hardware (accelerometer, gyroscope, ambient light, proximity, magnetometer) is wired to the SLPI DSP. Linux communicates with the sensor subsystem via Qualcomm IPC Router (`qrtr`) / FastRPC (`/dev/fastrpc-sdsp`).

```
 +---------------------------------------------------------+
 |                      Linux Userspace                    |
 |                                                         |
 |  monitor-sensor / Desktop Environment (Phosh/GNOME)     |
 |                         ^                               |
 |                         | D-Bus                         |
 |                 iio-sensor-proxy                        |
 |                         ^                               |
 |                         |                               |
 |                 libssc / ssccli                         |
 |                         ^                               |
 |                         | QRTR / FastRPC                |
 |                   hexagonrpcd                           |
 |          (serves registry & configs via HFS)            |
 +-------------------------+-------------------------------+
                           |
 +-------------------------v-------------------------------+
 |                      Linux Kernel                       |
 |                                                         |
 |  remoteproc (slpi) <---> rpmsg_char <---> fastrpc       |
 +-------------------------+-------------------------------+
                           |
 +-------------------------v-------------------------------+
 |                        Hardware                         |
 |                                                         |
 |                    SLPI DSP Firmware                    |
 |             (sensors.slpi / Kona sensors pd)            |
 |                         |                               |
 |  +---------------+---------------+---------------+      |
 |  | Accelerometer |   Gyroscope   |  Light / Prox | ...  |
 |  +---------------+---------------+---------------+      |
 +---------------------------------------------------------+
```

## Required Kernel Components

- **Remote processor:** SLPI remoteproc driver (`drivers/remoteproc/qcom_q6v5_slpi.c`) loading `postmarketos/slpi.mbn`.
- **FastRPC:** `CONFIG_RPMSG_CHAR=m`, `CONFIG_QUALCOMM_FASTRPC=m` providing `/dev/fastrpc-sdsp`.
- **Devicetree & Driver Support:**
  - FastRPC suspend/resume fixes (preventing system lockup during remote processor suspend transitions).
  - `oneplus-sensor-devinfo` driver providing device hardware ID and sensor orientation metadata via sysfs and initializing SMEM item 130.
  - SMEM item 130 sensor layout requires `oneplus,sources-per-sensor = <2>;` (vector stride 372 bytes / 0x174) so that sensor type 2 (MMC5603 magnetometer) is located at offset 748, matching SLPI Kona DSP firmware expectations. Fixed in `2620e8e643a6` and `a9a912406fd2`.

## Userspace Implementation & Staging

### 1. `hexagonrpcd`

`hexagonrpcd` runs as a reverse-RPC service (`hexagonrpcd-sdsp.service`) attached to `/dev/fastrpc-sdsp`. When SLPI boots, it issues FastRPC filesystem requests back to userspace to load its calibration registry and JSON configuration files.

The following patches (from the reference OnePlus 8 Pro port) are required:
- **0001 (`sns_reg_version`)**: Exposes `sns_reg_version` in the root and persist virtual filesystem so SLPI accepts the registry schema.
- **0002 (Buffer size fix)**: Allows the `adsp_listener` to fetch buffers larger than 256 bytes (required for registry group updates).
- **0003 (Method IDs > 30)**: Dispatches extended FastRPC method IDs via method 31 (e.g. `apps_std_frename`).
- **0004 & 0005 (Writable persist registry)**: Adds `-w <dir>` support to allow SLPI to read and write runtime calibration data into a writable directory (`/var/lib/hexagonrpcd/sensors-registry`).
- **ODM path mapping**: Maps `/odm/etc/sensor/config` to `/usr/share/qcom/sm8250/OnePlus/instantnoodlep/sensors/config` in `rpcd_builder.c`, matching vendor firmware paths queried by the SLPI Kona DSP image.

To survive reboot:
- The systemd unit is enabled (`systemctl enable hexagonrpcd-sdsp.service`) with a drop-in override (`/etc/systemd/system/hexagonrpcd-sdsp.service.d/override.conf`) configuring `-w /var/lib/hexagonrpcd/sensors-registry`.
- A symlink alias `/etc/systemd/system/hexagonrpcd.service` is provided for standard service resolution.
- A udev rule (`/etc/udev/rules.d/80-hexagonrpcd.rules`) triggers service start on `/dev/fastrpc-sdsp` device node creation:
  ```udev
  SUBSYSTEM=="misc", KERNEL=="fastrpc-sdsp*", TAG+="systemd", ENV{SYSTEMD_WANTS}+="hexagonrpcd-sdsp.service"
  ```

### 2. Registry and Configuration Layout

Configuration files staged from vendor and odm partitions:
- Read-only config directory: `/usr/share/qcom/sm8250/OnePlus/instantnoodlep/sensors/config/` (contains device JSON configs such as `kona_default_sensors.json`, `alsps.json`, `bmi26x_0.json`, etc.).
- Read-only registry configuration: `/usr/share/qcom/sm8250/OnePlus/instantnoodlep/sensors/sns_reg.conf`.
- Writable persist directory: `/var/lib/hexagonrpcd/sensors-registry/` (contains writable `registry/` and `sns_reg_version`, owned by `fastrpc:fastrpc`).

### 3. `iio-sensor-proxy` Integration

`iio-sensor-proxy` binds to FastRPC sensor devices. On SM8250:
- A custom udev rule override (`/etc/udev/rules.d/80-iio-sensor-proxy.rules`) is required to advertise accelerometer and proximity capabilities:
  ```udev
  ACTION=="add", SUBSYSTEM=="misc", KERNEL=="fastrpc-sdsp*", ENV{IIO_SENSOR_PROXY_TYPE}+="ssc-accel ssc-proximity"
  ```
- Combined with upstream rules, `IIO_SENSOR_PROXY_TYPE` includes `ssc-accel ssc-proximity ssc-light ssc-compass`.

## Measured Live Verification

Measured on **OnePlus 8 Pro IN2023 (`instantnoodlep`)** on **2026-11-27**, running kernel **`7.2.0-ga9a912406fd2`** (commit `a9a912406fd2`, boot ID `afecbd69-0b00-4944-8356-1d2862215e93`):

| Sensor | Status | Method / Tool | Measured Values & Units |
| --- | --- | --- | --- |
| **Accelerometer** | **Verified Live** | `ssccli --sensor accelerometer`<br>`monitor-sensor` | $X \approx 0.58 - 0.60\,\text{m/s}^2$, $Y \approx 0.43 - 0.45\,\text{m/s}^2$, $Z \approx 9.89 - 9.92\,\text{m/s}^2$<br>Tilt: `face-up` |
| **Ambient Light** | **Verified Live** | `ssccli --sensor light`<br>`monitor-sensor` | $\approx 350 - 360\,\text{Lux}$ |
| **Proximity** | **Verified Live** | `ssccli --sensor proximity`<br>`monitor-sensor` | Status: `FAR`<br>Near state: `0` |
| **Gyroscope** | **Verified Live** | `ssccli --sensor gyroscope`<br>`libssc` client | $X \approx -0.0127 - -0.0139\,\text{rad/s}$, $Y \approx -0.0043 - -0.0055\,\text{rad/s}$, $Z \approx 0.0027 - 0.0039\,\text{rad/s}$ |
| **Magnetometer / Compass** | **Verified Live** | `ssccli -v --sensor magnetometer`<br>`monitor-sensor --compass` | $X \approx 121.0 - 122.4\,\mu\text{T}$, $Y \approx -18.9 - -19.7\,\mu\text{T}$, $Z \approx 78.0 - 79.8\,\mu\text{T}$<br>Compass heading: $\approx 285.0^\circ$ (MMC5603). |
| **Additional SSC Algorithms** | **Active** | `libssc` discovery | `gravity`, `game_rv`, `tilt`, `amd` (absolute motion detector), `rmd` (relative motion detector) are registered and responsive. |

### Stability

SLPI remote processor (`remoteproc0`) remained stable under continuous sensor polling and clean stop/start cycles:
- State verified via `/sys/class/remoteproc/remoteproc0/state` (`running`).
- No DSP watchdog bites, kernel panics, or crash loops observed across observation window.
