#!/bin/sh
# Lancé par squeezelite@<name>.service. Env (/etc/squeezelite/<name>.env) : NAME, SQ_MAC, SINK (préfixe), BT_MAC (optionnel), SERVER (IP de MA, défaut 127.0.0.1).
set -eu

[ -n "${BT_MAC:-}" ] && bluetoothctl connect "$BT_MAC" >/dev/null 2>&1 || true

# "<index> <nom>" du 1er sink dont le nom commence par $1 (les noms varient : .1, .a2dp-sink…)
sink() { pactl list short sinks | awk -v p="$1" 'index($2, p) == 1 {print $1" "$2; exit}'; }

cur=""
for _ in $(seq 60); do  # BT lent au boot quand MA charge la Pi
  cur=$(sink "$SINK"); [ -n "$cur" ] && break; sleep 1
done
[ -n "$cur" ] || { echo "sink '$SINK' introuvable" >&2; exit 1; }

squeezelite-pulseaudio -n "$NAME" -m "$SQ_MAC" -o "${cur#* }" -s "${SERVER:-127.0.0.1}" &
pid=$!

# Si le sink disparaît ou est recréé (BT qui décroche/reconnecte), PipeWire bascule le flux
# sur "silence" : on sort, systemd relance et se recâble sur le bon sink.
while kill -0 "$pid" 2>/dev/null; do
  sleep 5
  [ "$(sink "$SINK")" = "$cur" ] || { echo "sink '$SINK' changé, relance" >&2; kill "$pid"; exit 1; }
done
exit 1
