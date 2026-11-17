#!/bin/bash
# Idempotent installer for octopus (multiroom audio). Usage: sudo ./install.sh   (safe to re-run)
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
U=${SUDO_USER:?run via sudo}
UID_U=$(id -u "$U")
HOME_U=$(getent passwd "$U" | cut -d: -f6)
SRC=$(cd "$(dirname "$0")" && pwd)

apt-get update
apt-get install -y pipewire pipewire-pulse wireplumber libspa-0.2-bluetooth bluez \
  pulseaudio-utils squeezelite-pulseaudio docker.io python3
systemctl disable --now squeezelite 2>/dev/null || true   # the package's default unit
usermod -aG bluetooth,docker "$U"
loginctl enable-linger "$U"   # user PipeWire session runs without login (headless)

# One A2DP speaker per BT adapter (Pi 3B+ onboard chip refuses a 2nd one): devices.json maps each to an adapter address.
CFG=/boot/firmware/config.txt; [ -f "$CFG" ] || CFG=/boot/config.txt
grep -q '^dtparam=audio=on' "$CFG" || echo 'dtparam=audio=on' >> "$CFG"   # 3.5 mm jack
grep -q '^gpu_mem=' "$CFG" || echo 'gpu_mem=16' >> "$CFG"   # headless: gives ~50 MB of RAM back
# Compressed swap in RAM (much faster than the SD card); recent RPi OS already ships it (rpi-swap)
swapon --show | grep -q zram || { apt-get install -y zram-tools; printf 'ALGO=zstd\nPERCENT=50\n' > /etc/default/zramswap; systemctl restart zramswap; }
# Memory cgroup (off by default on Pi): lets Docker cap Music Assistant's RAM
CMD=$(dirname "$CFG")/cmdline.txt
grep -q cgroup_memory "$CMD" || sed -i '1 s/$/ cgroup_enable=memory cgroup_memory=1/' "$CMD"
rfkill unblock bluetooth || true
# Disable Wi-Fi power saving (otherwise audio dropouts while streaming)
printf '[connection]\nwifi.powersave = 2\n' > /etc/NetworkManager/conf.d/wifi-powersave-off.conf
iw dev wlan0 set power_save off 2>/dev/null || true
sed -i 's/^#\?AutoEnable=.*/AutoEnable=true/' /etc/bluetooth/main.conf   # BT powered on at boot

# User PipeWire: "silence" as default sink (if a BT speaker drops, its stream goes there
# instead of the amp) + BT enabled without a graphical seat (WirePlumber 0.4 and 0.5).
install -d -o "$U" -g "$U" "$HOME_U/.config/pipewire/pipewire.conf.d" \
  "$HOME_U/.config/wireplumber/bluetooth.lua.d" "$HOME_U/.config/wireplumber/wireplumber.conf.d"
cat > "$HOME_U/.config/pipewire/pipewire.conf.d/50-silence.conf" <<'EOF'
context.objects = [
  { factory = adapter
    args = { factory.name = support.null-audio-sink node.name = "silence"
             media.class = Audio/Sink audio.position = [ FL FR ]
             priority.session = 2000 } } ]
EOF
echo 'bluez_monitor.properties["with-logind"] = false' \
  > "$HOME_U/.config/wireplumber/bluetooth.lua.d/80-no-logind.lua"
echo 'wireplumber.profiles = { main = { monitor.bluez.seat-monitoring = disabled } }' \
  > "$HOME_U/.config/wireplumber/wireplumber.conf.d/80-no-logind.conf"
chown -R "$U:$U" "$HOME_U/.config/pipewire" "$HOME_U/.config/wireplumber"

# Music Assistant
# ponytail: RAM cap for 1 GB Pi (first start otherwise freezes it); drop on a Pi with >= 2 GB
docker inspect music-assistant >/dev/null 2>&1 || docker run -d --name music-assistant \
  --network host --restart unless-stopped --memory 650m --memory-swap 900m \
  -v /opt/ma:/data ghcr.io/music-assistant/server:latest

# Project files
rm -rf /opt/multiroom /etc/sudoers.d/multiroom   # former project name
install -d /opt/octopus /etc/squeezelite
install -m 755 "$SRC/sq-run.sh" "$SRC/panel.py" /opt/octopus/
install -m 644 "$SRC/devices.json" /opt/octopus/
for f in squeezelite@.service panel.service; do
  sed "s/__USER__/$U/; s/__UID__/$UID_U/" "$SRC/$f" > "/etc/systemd/system/$f"
done
cat > /etc/sudoers.d/octopus <<EOF
$U ALL=(root) NOPASSWD: /usr/bin/systemctl enable --now squeezelite@*, /usr/bin/systemctl disable --now squeezelite@*, /usr/bin/systemctl try-restart squeezelite@*
EOF
chmod 440 /etc/sudoers.d/octopus
visudo -cf /etc/sudoers.d/octopus

# One .env per output; prints the outputs to enable by default (bt / local).
TO_ENABLE=$(python3 - <<'EOF'
import hashlib, json
for d in json.load(open("/opt/octopus/devices.json")):
    n, mac = d["name"], d.get("mac", "")
    h = hashlib.md5(n.encode()).hexdigest()
    sq_mac = "02:" + ":".join(h[i:i+2] for i in range(0, 10, 2))  # unique per instance, otherwise MA merges them
    sink = d.get("sink") or "bluez_output." + mac.replace(":", "_")
    open(f"/etc/squeezelite/{n}.env", "w").write(
        f"NAME={n}\nSQ_MAC={sq_mac}\nSINK={sink}\nBT_MAC={mac}\nADAPTER={d.get('adapter', '')}\n")
    if d["default_mode"] in ("bt", "local"):
        print(n)
EOF
)

systemctl daemon-reload
systemctl enable --now panel
for n in $TO_ENABLE; do systemctl enable "squeezelite@$n"; systemctl restart "squeezelite@$n"; done
echo "OK. Music Assistant: http://$(hostname).local:8095 — Panel: http://$(hostname).local:8080"
echo "First install: reboot the Pi (linger + groups)."
