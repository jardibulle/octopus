#!/bin/bash
# Install idempotente d'octopus (multiroom). Usage : sudo ./install.sh   (relançable sans risque)
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "lancer avec sudo" >&2; exit 1; }
U=${SUDO_USER:?lancer via sudo}
UID_U=$(id -u "$U")
HOME_U=$(getent passwd "$U" | cut -d: -f6)
SRC=$(cd "$(dirname "$0")" && pwd)

apt-get update
apt-get install -y pipewire pipewire-pulse wireplumber libspa-0.2-bluetooth bluez \
  pulseaudio-utils squeezelite-pulseaudio docker.io python3
systemctl disable --now squeezelite 2>/dev/null || true   # l'unit par défaut du paquet
usermod -aG bluetooth,docker "$U"
loginctl enable-linger "$U"   # session PipeWire du user active sans login (headless)

# Pi 3B+ : BT intégré seul (hci0), partagé avec le Wi-Fi → Ethernet conseillé.
# ponytail: 1 puce pour toutes les enceintes BT ; ajouter des dongles USB si ça hache à 3+ enceintes.
CFG=/boot/firmware/config.txt; [ -f "$CFG" ] || CFG=/boot/config.txt
grep -q '^dtparam=audio=on' "$CFG" || echo 'dtparam=audio=on' >> "$CFG"   # prise jack
grep -q '^gpu_mem=' "$CFG" || echo 'gpu_mem=16' >> "$CFG"   # headless : rend ~50 Mo de RAM au système
# Swap compressé en RAM (bien plus rapide que la SD) ; les RPi OS récents l'ont déjà (rpi-swap)
swapon --show | grep -q zram || { apt-get install -y zram-tools; printf 'ALGO=zstd\nPERCENT=50\n' > /etc/default/zramswap; systemctl restart zramswap; }
# cgroup mémoire (désactivé par défaut sur Pi) : permet de plafonner la RAM de MA
CMD=$(dirname "$CFG")/cmdline.txt
grep -q cgroup_memory "$CMD" || sed -i '1 s/$/ cgroup_enable=memory cgroup_memory=1/' "$CMD"
rfkill unblock bluetooth || true
# Wi-Fi sans économie d'énergie (sinon micro-coupures en streaming)
printf '[connection]\nwifi.powersave = 2\n' > /etc/NetworkManager/conf.d/wifi-powersave-off.conf
iw dev wlan0 set power_save off 2>/dev/null || true
sed -i 's/^#\?AutoEnable=.*/AutoEnable=true/' /etc/bluetooth/main.conf   # BT allumé au boot

# PipeWire côté user : sink "silence" par défaut (si une enceinte BT tombe, son flux part là
# au lieu de sortir sur l'ampli) + BT actif sans session graphique (WP 0.4 et 0.5).
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
# ponytail: plafond RAM pour Pi 1 Go (sinon le 1er démarrage fige la Pi) ; à retirer sur Pi ≥ 2 Go
docker inspect music-assistant >/dev/null 2>&1 || docker run -d --name music-assistant \
  --network host --restart unless-stopped --memory 650m --memory-swap 900m \
  -v /opt/ma:/data ghcr.io/music-assistant/server:latest

# Fichiers du projet
rm -rf /opt/multiroom /etc/sudoers.d/multiroom   # ancien nom du projet
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

# Un .env par sortie ; renvoie les sorties à activer par défaut (bt / local).
TO_ENABLE=$(python3 - <<'EOF'
import hashlib, json
for d in json.load(open("/opt/octopus/devices.json")):
    n, mac = d["name"], d.get("mac", "")
    h = hashlib.md5(n.encode()).hexdigest()
    sq_mac = "02:" + ":".join(h[i:i+2] for i in range(0, 10, 2))  # unique par instance, sinon MA les confond
    sink = d.get("sink") or "bluez_output." + mac.replace(":", "_")
    open(f"/etc/squeezelite/{n}.env", "w").write(f"NAME={n}\nSQ_MAC={sq_mac}\nSINK={sink}\nBT_MAC={mac}\n")
    if d["default_mode"] in ("bt", "local"):
        print(n)
EOF
)

systemctl daemon-reload
systemctl enable --now panel
for n in $TO_ENABLE; do systemctl enable "squeezelite@$n"; systemctl restart "squeezelite@$n"; done
echo "OK. Music Assistant : http://$(hostname).local:8095 — Panel : http://$(hostname).local:8080"
echo "Si 1re install : redémarre la Pi (linger + groupes)."
