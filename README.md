# UnTuyaOS3

Freeing some TuyaOS 3 devices with custom firmware.

> **Linux only.** The flashing step uses `iw` to scan/associate and needs root
> for the wireless operations. Tested on Raspberry Pi OS (Debian).

This will only work on some TuyaOS 3 devices.  There is no clear-cut way to determine which devices are TuyaOS3.  The closest current way to check is usually by known firmware version, see the [FAQ](#FAQ) section for user-maintained device compatibility information.  If you're not sure, it can't hurt to try, if the exploit fails, your device will remain unchanged.

## Prerequisites

- A Linux host with a Wi-Fi adapter, `iw`, a Docker engine (`docker` / `docker.io`)
  and `docker-cli` (a hard requirement). All are installed automatically on first
  run if missing.
- Root privileges for moving the Wi-Fi interface, Docker, and package installation.
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

3. Answer the platform and firmware prompts. The script then starts a container
   (`python:3` based, with all Python requirements pip-installed inside it),
   passes the Wi-Fi interface into it, waits for the device's AP, connects
   (DHCP runs inside the container, so the host's DNS is untouched), uploads the
   firmware, and hands the interface back to the host.

### Options

```text
./UnTuyaOS3.sh [options]

  -h, -?, --help     show this help and exit
  -v, --verbose      enable verbose logging
```

- **`-v` / `--verbose`** — replaces the upload progress bar with the full
  per-frame TX/RX protocol log from `ap-ota.py` (useful for debugging).
- **`-h` / `-?` / `--help`** — prints usage and exits without doing anything.

## Notes & cautions

- **Flashing custom firmware is at your own risk** and may brick the device or
  void its warranty.
- If a device becomes bricked, serial flashing will be the only recovery method.
- The container image is built once as `untuyaos3`; `docker rmi untuyaos3` forces a rebuild.
- If the device's AP and your normal network share a single Wi-Fi radio,
  connecting to the device will drop your other connection on that interface
  (including an SSH-over-Wi-Fi session).

## FAQ

- Frequently asked questions can be found on the [wiki FAQ page](https://github.com/tuya-cloudcutter/UnTuyaOS3/wiki/FAQ)
- While there is no definitive list of supported or unsupported devices, a user-editable page will be maintained at the [Device Compatibility Wiki](https://github.com/tuya-cloudcutter/UnTuyaOS3/wiki/Device-Compatibility)


## Thanks

A huge thank you to [kuba2k2](https://github.com/kuba2k2) of the [LibreTiny Project](https://github.com/libretiny-eu/libretiny) for finding and sharing this exploit!  If you find this tool useful, please consider [sponsoring the LibreTiny project](https://github.com/libretiny-eu/libretiny/#:~:text=Sponsor%20this%20project) to support the ongoing work to freeing your devices!
