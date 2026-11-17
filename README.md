# Octopus

Multiroom audio on a Raspberry Pi: Music Assistant (Spotify, Deezer, groups) + one squeezelite instance per Bluetooth/jack output + a tiny Bluetooth status panel.

## Setup

1. Pair each Bluetooth speaker once, on its own adapter (`bluetoothctl list`): `bluetoothctl` → `select <adapter address>` → `menu scan` → `transport bredr` → `back` → `scan on` → `pair <MAC>` → `trust <MAC>`.
   Use the classic (BR/EDR) address, not the BLE one some Cast speakers also advertise.
2. Fill in `devices.json`: speaker `mac` and its `adapter` address (not `hciN`, which can change across boots). For the jack output, set `sink` to the prefix shown by `pactl list short sinks` (e.g. `alsa_output.platform-...`).
3. Run `sudo ./install.sh` (Raspberry Pi OS Lite **64-bit**), then reboot the first time. Safe to re-run.
4. Music Assistant at `http://octopus.local:8095`: add the Spotify (and Deezer, via ARL token) music providers and the Squeezelite player provider.
   Create a **sync group** with the squeezelite players: they play in sync natively.
5. Panel at `http://octopus.local:8080`: Bluetooth status, reconnect, Cast/BT switch.

## Notes

- **One A2DP speaker per Bluetooth adapter**: the Pi 3B+ onboard chip refuses a second audio connection (`br-connection-create-socket`). Add a USB adapter (e.g. RTL8761B) per extra speaker.
- **Pi 3B+ (1 GB RAM)**: `install.sh` caps Music Assistant at 650 MB (`gpu_mem=16`, memory cgroup, zram) so the first start can't freeze the Pi.
- **Cast speakers** can join a Music Assistant *universal group*, but their latency (~2 s) is only aligned manually via each player's *sync adjust*.
- Music Assistant on another machine: add `SERVER=<ip>` to `/etc/squeezelite/<name>.env`.

Test: `python3 test_panel.py`.

## TODO

- "Ask Claude" debug page on the panel: see [docs/TODO-debug-assistant.md](docs/TODO-debug-assistant.md).
