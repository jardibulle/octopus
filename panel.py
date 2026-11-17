#!/usr/bin/env python3
"""Octopus mini panel: BT status, reconnect, Cast <-> BT switch. Stdlib only."""
import json
import os
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEVICES = os.environ.get("DEVICES", "/opt/octopus/devices.json")
PORT = int(os.environ.get("PORT", "8080"))
MA_SETTINGS = os.environ.get("MA_SETTINGS", "/opt/ma/settings.json")
SOURCES = ("spotify", "deezer")


def sources(path=MA_SETTINGS):
    """Sources configured in Music Assistant, read from its settings.json.
    ponytail: 'configured' != 'valid token'; use the MA API if the real status is needed."""
    try:
        with open(path) as f:
            provs = json.load(f).get("providers", {}).values()
    except (OSError, ValueError):
        return {s: None for s in SOURCES}  # unknown
    on = {p.get("domain") for p in provs if isinstance(p, dict) and p.get("enabled", True)}
    return {s: s in on for s in SOURCES}


def load():
    with open(DEVICES) as f:
        return json.load(f)


def find(devices, name):
    """Only names from devices.json pass: raw input never reaches a command."""
    for d in devices:
        if d["name"] == name and d.get("mac"):
            return d
    raise KeyError(name)


def parse_connected(out):
    return out.strip() == "b true"  # busctl get-property output


def run(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=30)


def adapter_path(addr):
    """D-Bus path of the BT adapter with this address (hciN numbering can change across boots)."""
    for n in sorted(os.listdir("/sys/class/bluetooth")):
        if ":" in n:  # hci0:12 = a connection, not an adapter
            continue
        out = run("busctl", "get-property", "org.bluez", f"/org/bluez/{n}", "org.bluez.Adapter1", "Address").stdout
        if f'"{addr.upper()}"' in out.upper():
            return f"/org/bluez/{n}"
    raise LookupError(addr)


def bt(d, *args):
    """busctl call/get-property on the device, through its own adapter."""
    path = adapter_path(d["adapter"]) + "/dev_" + d["mac"].replace(":", "_")
    return run("busctl", *args[:1], "org.bluez", path, "org.bluez.Device1", *args[1:])


def status(d):
    try:
        connected = parse_connected(bt(d, "get-property", "Connected").stdout)
    except (LookupError, OSError):
        connected = False
    active = run("systemctl", "is-active", f"squeezelite@{d['name']}").stdout.strip() == "active"
    return {"name": d["name"], "modes": d["modes"], "connected": connected,
            "mode": "bt" if active else "cast"}


def reconnect(d):
    bt(d, "call", "Connect")
    # If the sink vanished, the stream slid to the "silence" sink: restart to reattach it.
    run("sudo", "-n", "systemctl", "try-restart", f"squeezelite@{d['name']}")


def set_mode(d, mode):
    if mode not in d["modes"]:
        raise ValueError(mode)
    unit = f"squeezelite@{d['name']}"
    if mode == "bt":
        run("sudo", "-n", "systemctl", "enable", "--now", unit)  # sq-run.sh does the BT connect
    else:
        run("sudo", "-n", "systemctl", "disable", "--now", unit)
        bt(d, "call", "Disconnect")  # frees the speaker for Cast


PAGE = """<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width">
<title>Octopus</title>
<style>body{font:16px system-ui;max-width:40em;margin:1em auto;padding:0 1em}
td{padding:.4em}.on{color:green}.off{color:#c00}</style>
<h1>Sources</h1><table id=s></table>
<h1>Speakers</h1><p><a href="" id=ma>Music Assistant</a></p><table id=t></table>
<script>
const MA = location.protocol + '//' + location.hostname + ':8095';
ma.href = MA;
fetch('/api/sources').then(r => r.json()).then(src => {
  s.innerHTML = Object.entries(src).map(([n, ok]) => `<tr><td><b>${n}</b></td>
    <td class=${ok?'on':'off'}>${ok===null?'unknown':ok?'configured':'not configured'}</td>
    <td><a href="${MA}/#/settings/providers">${ok?'Manage':'Set up'} in MA</a></td></tr>`).join('');
});
async function post(u){await fetch(u,{method:'POST'});load()}
async function load(){
  const ds = await (await fetch('/api/devices')).json();
  t.innerHTML = ds.map(d => `<tr><td><b>${d.name}</b></td>
    <td class=${d.connected?'on':'off'}>${d.connected?'BT connected':'BT disconnected'}</td>
    <td><button onclick="post('/api/${d.name}/reconnect')">Reconnect</button></td>
    <td>${d.modes.length>1 ? d.modes.map(m=>`<button ${m==d.mode?'disabled':''}
      onclick="post('/api/${d.name}/mode?m=${m}')">${m}</button>`).join(' ') : d.modes[0]}</td></tr>`).join('');
}
load(); setInterval(load, 5000);
</script>"""


class H(BaseHTTPRequestHandler):
    def send(self, code, body, ctype="application/json"):
        b = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path == "/":
            return self.send(200, PAGE, "text/html; charset=utf-8")
        if self.path == "/api/devices":
            return self.send(200, json.dumps([status(d) for d in load() if d.get("mac")]))
        if self.path == "/api/sources":
            return self.send(200, json.dumps(sources()))
        self.send(404, "{}")

    def do_POST(self):
        path, _, query = self.path.partition("?")
        parts = path.strip("/").split("/")  # api/<name>/<action>
        try:
            if len(parts) != 3 or parts[0] != "api":
                raise KeyError(path)
            d = find(load(), parts[1])
            if parts[2] == "reconnect":
                reconnect(d)
            elif parts[2] == "mode":
                set_mode(d, query.removeprefix("m="))
            else:
                raise KeyError(parts[2])
        except (KeyError, ValueError):
            return self.send(400, "{}")
        except LookupError:  # adapter not plugged in
            return self.send(503, "{}")
        self.send(200, "{}")


if __name__ == "__main__":
    # ponytail: no auth, LAN only. Put an authenticating reverse proxy in front if exposed.
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
