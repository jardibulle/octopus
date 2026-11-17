# TODO: "Ask Claude" debug page

**Status:** not started. This doc gathers the context needed to build it later.

## Goal

A page on the panel (e.g. `http://octopus.local:8080/debug`) that, when a speaker misbehaves:

1. collects a snapshot of the Pi's state (read-only commands, below);
2. sends it to Claude with the project context and the known failure modes;
3. shows a diagnosis and the next steps in plain language — so someone who is not the author can fix the usual problems alone.

## Why

Every incident so far was diagnosed the same way: run 5–10 read-only commands, read the output, match it against a handful of known causes. That loop is what this page automates.

## Known failure modes (seed for the system prompt)

| Symptom | Evidence | Cause / fix |
|---|---|---|
| Pi unreachable, SSH times out | `vcgencmd get_throttled` ends in `5` (e.g. `0x50005`) | Under-voltage. Official 5.1 V / 2.5 A PSU, short cable, or powered USB hub for BT adapters. |
| Pi freezes on first Music Assistant start | swap full, MA container RAM | 1 GB RAM. `install.sh` caps MA (`--memory 650m`, `gpu_mem=16`, memory cgroup, zram). |
| 2nd BT speaker won't connect | `br-connection-create-socket` | One A2DP speaker per adapter (Pi 3B+ onboard chip). Pair it on a USB adapter (`bluetoothctl select <adapter>`). |
| USB BT adapter drops every few minutes | dmesg `hciN: hardware error 0x01`, `build 0000` | Broadcom BCM20702 without patch → install `BCM20702A1-0a5c-21e8.hcd` (done by `install.sh`), replug. |
| Adapter `NotReady` / `power on` fails | `org.bluez.Error.NotReady` / `Failed` | `rfkill unblock all`; firmware missing (see above); `busctl set-property … Powered b true`. |
| Speaker "connected" but silent | `pactl list short sink-inputs` shows the stream on `silence` | WirePlumber parked it; `sq-run.sh` now moves it back every 5 s. |
| Speaker plays but very quiet | sink volume ~30 % and stream ~25 % multiply | `pactl set-sink-volume <sink> 100%`, control volume from MA only. |
| `connect` fails with `le-connection-abort-by-local` | address starts with a random-looking prefix | That's the BLE address (Cast setup). Scan with `transport bredr`, use the classic address. |
| `page-timeout` | busctl `Connect` | Speaker off, asleep, or out of range. |
| `In Progress` | busctl `Connect` | A connection attempt is already running (service retrying); wait or `Disconnect` first. |
| `adapter … not found` in squeezelite log | `bluetoothctl list` | USB adapter unplugged or crashed (often power). |

## Diagnostics to collect (read-only, fixed list)

```
vcgencmd get_throttled
free -h; docker stats --no-stream music-assistant
bluetoothctl list                     # + busctl Address/Powered per /org/bluez/hciN
bluetoothctl devices Connected
pactl list short sinks; pactl list short sink-inputs
systemctl is-active squeezelite@*  ;  journalctl -u 'squeezelite@*' -n 50
dmesg | grep -iE 'hci|bluetooth|usb|voltage' | tail -50
cat /opt/octopus/devices.json
```

Never collect `/opt/ma/settings.json` or MA logs (Spotify/Deezer tokens).

## Design sketch

- **Call the Claude API with the official Python SDK** (`anthropic`), installed in a venv (`/opt/octopus/venv`) so the rest of the panel stays stdlib-only.
- **Model:** `claude-opus-5-5` (default; adaptive thinking is always on, effort defaults to `medium` — set it explicitly). Cheaper alternatives if cost matters: `claude-sonnet-5-5`, `claude-haiku-5-5` — to be decided by measuring on real incidents.
- **Refusal fallback:** with Opus 5.5, enable server-side fallbacks by default (`betas=["server-side-fallback-2026-07-01"]`, `fallbacks="default"`) and always check `stop_reason` before reading `content`.
- **Simplest version first:** one Messages call with the snapshot in the user message. Upgrade to tool use (read-only tools such as `journal(unit)`, `bt_info(name)`) only if one snapshot proves insufficient — the model asks for more, the panel runs only whitelisted commands with arguments validated against `devices.json`.
- **The model never acts.** It suggests; actions (reconnect, restart, set volume) stay as buttons the human clicks, reusing the panel's existing endpoints.
- **Prompt caching:** put the stable part first — system prompt with README, architecture, the table above — with `cache_control` (prefix ≥ the model's minimum cacheable size), and the volatile snapshot after it. Check `usage.cache_read_input_tokens` > 0 on the second call.
- **Streaming** the answer to the page (SSE or chunked response) so people see progress.

## Security (must-haves before shipping)

- **API key:** in `/etc/octopus/anthropic.env` (`chmod 600`, root), loaded by the unit's `EnvironmentFile=`; never in the repo or the page.
- **Auth on the page:** the panel has none today. Anyone reaching `/debug` spends the owner's tokens → add at least a shared password, and a rate limit (e.g. 1 request / minute).
- **Exposure:** the Pi has a public IPv6 (Freebox). Verify it isn't reachable from the Internet (IPv6 firewall on the box, or `net.ipv6.conf.all.disable_ipv6=1`) before adding this page.
- **Prompt injection:** diagnostic output includes untrusted text (Bluetooth device names from nearby devices, logs). Put it inside clearly delimited data blocks, tell the model it is data, and never execute anything the model returns.
- **Spend cap:** set a monthly spend limit on the API key in the Console.

## Cost (order of magnitude)

Prices per million tokens (input / output): Opus 5.5 $4 / $20 (cache reads $0.20), Sonnet 5.5 $2 / $10, Haiku 5.5 $0.10 / $0.50.
A request is roughly 5–10 k tokens of context (mostly cached after the first call) + a few k of snapshot + 1–2 k of answer → a few cents with Opus 5.5, well under a cent with Haiku 5.5. Measure on real incidents before choosing.
