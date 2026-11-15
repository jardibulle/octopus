#!/bin/sh
# Started by squeezelite@<name>.service. Env (/etc/squeezelite/<name>.env): NAME, SQ_MAC, SINK (prefix), BT_MAC (optional), SERVER (Music Assistant IP, default 127.0.0.1).
set -eu

[ -n "${BT_MAC:-}" ] && bluetoothctl connect "$BT_MAC" >/dev/null 2>&1 || true

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
