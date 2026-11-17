#!/bin/sh
# Started by squeezelite@<name>.service. Env (/etc/squeezelite/<name>.env): NAME, SQ_MAC, SINK (prefix), BT_MAC + ADAPTER (BT controller address, optional), SERVER (Music Assistant IP, default 127.0.0.1).
set -eu

# Connect through the speaker's own adapter, found by address (hciN numbering changes across boots).
if [ -n "${BT_MAC:-}" ]; then
  ap=""
  for n in $(ls /sys/class/bluetooth | grep -v :); do
    busctl get-property org.bluez "/org/bluez/$n" org.bluez.Adapter1 Address 2>/dev/null \
      | grep -qi "\"${ADAPTER:-}\"" && ap="/org/bluez/$n" && break
  done
  [ -n "$ap" ] || { echo "adapter $ADAPTER not found" >&2; exit 1; }
  busctl call org.bluez "$ap/dev_$(echo "$BT_MAC" | tr : _)" org.bluez.Device1 Connect >/dev/null 2>&1 || true
fi

# "<index> <name>" of the first sink whose name starts with $1 (suffixes vary: .1, .a2dp-sink…)
sink() { pactl list short sinks | awk -v p="$1" 'index($2, p) == 1 {print $1" "$2; exit}'; }

cur=""
for _ in $(seq 60); do  # BT is slow at boot while Music Assistant loads the Pi
  cur=$(sink "$SINK"); [ -n "$cur" ] && break; sleep 1
done
[ -n "$cur" ] || { echo "sink '$SINK' not found" >&2; exit 1; }

squeezelite-pulseaudio -n "$NAME" -m "$SQ_MAC" -o "${cur#* }" -s "${SERVER:-127.0.0.1}" &
pid=$!

# If the sink disappears or is recreated (BT drop/reconnect), PipeWire moves the stream to
# "silence": exit so systemd restarts us and we reattach to the right sink.
while kill -0 "$pid" 2>/dev/null; do
  sleep 5
  [ "$(sink "$SINK")" = "$cur" ] || { echo "sink '$SINK' changed, restarting" >&2; kill "$pid"; exit 1; }
done
exit 1
