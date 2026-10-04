# UnTuyaOS3

Freeing some TuyaOS 3 devices with custom firmware.

> **Linux only.** The flashing step uses `iw` to scan/associate and needs root
> for the wireless operations. Tested on Raspberry Pi OS (Debian).

This will only work on some TuyaOS 3 devices.  There is no clear-cut way to determine which devices are TuyaOS3.  The closest current way to check is usually by known firmware version, see the [FAQ](#FAQ) section for user-maintained device compatibility information.  If you're not sure, it can't hurt to try, if the exploit fails, your device will remain unchanged.

## Prerequisites

- A Linux host with a Wi-Fi adapter and `iw` available (installed automatically
  in step 1 if missing).
- Root privileges for the Wi-Fi scan/associate/disconnect operations and package installation.
- One or more valid `UG` firmware files placed in the platform folder under
  `custom-firmware/` (see below).
- A compatible TuyaOS3 device.

## Firmware layout

Place Tuya UG format firmware images under a per-platform directory at the project root:

```text
custom-firmware/
├── T1/
│   └── <your-t1-ug-firmware>
├── BK7231N/
│   └── <your-bk7231n-ug-firmware>
└── RTL8720CF/
    └── <your-rtl8720cf-ug-firmware>
```

A valid image must contain the platform's signature bytes, or selection fails to help ensure the wrong file type is not used:

| Platform  | Bytes checked       | Required value                                    |
| --------- | ------------------- | ------------------------------------------------- |
| T1        | first 4 (bytes 0-4) | `4D 4D 4D 00`                                     |
| BK7231N   | first 4 (bytes 0-4) | `55 AA 55 AA`                                     |
| RTL8720CF | bytes 32-48         | `68 51 3E F8 3E 39 6B 12 BA 05 9A 90 0F 36 B6 D3` |

ESPHome Kickstart images are included by default, sourced from <https://github.com/libretiny-eu/esphome-kickstart/releases>.

## Usage

1. Put the device into **AP mode** (typically a slow blink).
2. From the project root, run `UnTuyaOS3.sh` as root. It is the entry point and performs every step itself including installing requirements.

   ```bash
   sudo ./UnTuyaOS3.sh
   ```

3. Answer the platform and firmware prompts. The script then waits for the
   device's AP, connects, uploads the firmware, and disconnects.

### Options

```text
./UnTuyaOS3.sh [options]

  -h, -?, --help             show this help and exit
  -v, --verbose              enable verbose logging
  -i, --interface IFACE      Wi-Fi interface to use (default: first found)
  -p, --platform PLATFORM    T1, BK7231N or RTL8720CF (skips the prompt)
  -f, --firmware FILE        firmware path, or a file name inside
                             custom-firmware/<platform>/ (skips the prompt)
```

- **`-v` / `--verbose`** — replaces the upload progress bar with the full
  per-frame TX/RX protocol log from `ap-ota.py` (useful for debugging).
- **`-h` / `-?` / `--help`** — prints usage and exits without doing anything.
- **`-i` / `--interface`** — the Wi-Fi interface to scan and connect with.
  Without it, the first interface `iw dev` lists is used, which may be the one
  your normal network is on.
- **`-p` / `--platform`**, **`-f` / `--firmware`** — preselect the platform and
  firmware instead of answering the prompts. The firmware is still checked
  against the platform's signature bytes.

Setting `UNTUYAOS3_SKIP_INSTALL=1` skips the requirements step, for when the
dependencies are already installed (the Docker image does this).

## Docker

The Docker image contains everything needed (the compiled Python dependencies,
`iw`, a DHCP client and the bundled firmware), so nothing is installed on the
host apart from Docker itself. The host must still be Linux with a Wi-Fi
adapter. Build it with:

```bash
docker compose build
```

A Wi-Fi adapter has no `/dev` node, so it can't be passed in with `--device`.
There are two ways to give the container one:

### Host networking (simplest)

The container shares the host's network, as when running natively. Only the
`NET_ADMIN` and `NET_RAW` capabilities are needed, not `--privileged`:

```bash
docker compose run --rm untuyaos3 -i wlan1
# or, without compose:
docker run --rm -it --network host --cap-add NET_ADMIN --cap-add NET_RAW \
    --device /dev/rfkill untuyaos3 -i wlan1
```

The host's network manager still manages the adapter, the same as when running
natively. The device's bogus DNS server can't reach the host, because the
container has its own `/etc/resolv.conf`.

### Isolated (dedicated adapter)

`docker/run-isolated.sh` moves the adapter into the container, so the host
can't use or interfere with it until the container exits. The kernel then
returns it to the host automatically. Run it as root on the Docker host:

```bash
sudo docker/run-isolated.sh wlan1
sudo docker/run-isolated.sh wlan1 -p BK7231N -f OpenBK7231N_UG_1.18.315.bin
```

The adapter's driver must support this; check that
`iw phy "$(cat /sys/class/net/wlan1/phy80211/name)" info` lists
`set_wiphy_netns`. Most USB and PCIe adapters do. If yours doesn't, use host
networking.

### Your own firmware

The firmware bundled in this repository is built into the image. To use other
files, mount your own `custom-firmware` folder over it: uncomment `volumes` in
`compose.yaml`, add `-v "$PWD/custom-firmware:/app/custom-firmware:ro"` to
`docker run`, or set `UNTUYAOS3_FIRMWARE_DIR=/path/to/custom-firmware` for
`docker/run-isolated.sh`.

## Notes & cautions

- **Flashing custom firmware is at your own risk** and may brick the device or
  void its warranty.
- If a device becomes bricked, serial flashing will be the only recovery method.
- If the device's AP and your normal network share a single Wi-Fi radio,
  connecting to the device will drop your other connection on that interface
  (including an SSH-over-Wi-Fi session).

## FAQ

- Frequently asked questions can be found on the [wiki FAQ page](https://github.com/tuya-cloudcutter/UnTuyaOS3/wiki/FAQ)
- While there is no definitive list of supported or unsupported devices, a user-editable page will be maintained at the [Device Compatibility Wiki](https://github.com/tuya-cloudcutter/UnTuyaOS3/wiki/Device-Compatibility)


## Thanks

A huge thank you to [kuba2k2](https://github.com/kuba2k2) of the [LibreTiny Project](https://github.com/libretiny-eu/libretiny) for finding and sharing this exploit!  If you find this tool useful, please consider [sponsoring the LibreTiny project](https://github.com/libretiny-eu/libretiny/#:~:text=Sponsor%20this%20project) to support the ongoing work to freeing your devices!
