#!/usr/bin/env python3
"""Mini panel multiroom : état BT, reconnexion, bascule Cast <-> BT. Stdlib uniquement."""
import json
import os
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEVICES = os.environ.get("DEVICES", "/opt/multiroom/devices.json")
PORT = int(os.environ.get("PORT", "8080"))
MA_SETTINGS = os.environ.get("MA_SETTINGS", "/opt/ma/settings.json")
SOURCES = ("spotify", "deezer")


def sources(path=MA_SETTINGS):
    """Sources configurées dans Music Assistant, lues dans son settings.json.
    ponytail: 'configuré' != 'token valide' ; passer par l'API MA si besoin du vrai statut."""
    try:
        with open(path) as f:
            provs = json.load(f).get("providers", {}).values()
    except (OSError, ValueError):
        return {s: None for s in SOURCES}  # inconnu
    on = {p.get("domain") for p in provs if isinstance(p, dict) and p.get("enabled", True)}
    return {s: s in on for s in SOURCES}


def load():
    with open(DEVICES) as f:
        return json.load(f)


def find(devices, name):
    """Seuls les noms de devices.json passent : jamais d'entrée brute vers une commande."""
    for d in devices:
        if d["name"] == name and d.get("mac"):
            return d
    raise KeyError(name)


def parse_connected(info):
    return any(l.strip() == "Connected: yes" for l in info.splitlines())


def run(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=30)


def status(d):
    connected = parse_connected(run("bluetoothctl", "info", d["mac"]).stdout)
    active = run("systemctl", "is-active", f"squeezelite@{d['name']}").stdout.strip() == "active"
    return {"name": d["name"], "modes": d["modes"], "connected": connected,
            "mode": "bt" if active else "cast"}


def reconnect(d):
    run("bluetoothctl", "connect", d["mac"])
    # Si le sink a disparu, le flux a glissé sur le sink "silence" : on relance pour le recâbler.
    run("sudo", "-n", "systemctl", "try-restart", f"squeezelite@{d['name']}")


def set_mode(d, mode):
    if mode not in d["modes"]:
        raise ValueError(mode)
    unit = f"squeezelite@{d['name']}"
    if mode == "bt":
        run("sudo", "-n", "systemctl", "enable", "--now", unit)  # sq-run.sh fait le connect BT
    else:
        run("sudo", "-n", "systemctl", "disable", "--now", unit)
        run("bluetoothctl", "disconnect", d["mac"])  # libère l'enceinte pour Cast


PAGE = """<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width">
<title>Multiroom</title>
<style>body{font:16px system-ui;max-width:40em;margin:1em auto;padding:0 1em}
td{padding:.4em}.on{color:green}.off{color:#c00}</style>
<h1>Sources</h1><table id=s></table>
<h1>Enceintes</h1><p><a href="" id=ma>Music Assistant</a></p><table id=t></table>
<script>
const MA = location.protocol + '//' + location.hostname + ':8095';
ma.href = MA;
fetch('/api/sources').then(r => r.json()).then(src => {
  s.innerHTML = Object.entries(src).map(([n, ok]) => `<tr><td><b>${n}</b></td>
    <td class=${ok?'on':'off'}>${ok===null?'état inconnu':ok?'configuré':'non configuré'}</td>
    <td><a href="${MA}/#/settings/providers">${ok?'Gérer':'Configurer'} dans MA</a></td></tr>`).join('');
});
async function post(u){await fetch(u,{method:'POST'});load()}
async function load(){
  const ds = await (await fetch('/api/devices')).json();
  t.innerHTML = ds.map(d => `<tr><td><b>${d.name}</b></td>
    <td class=${d.connected?'on':'off'}>${d.connected?'BT connecté':'BT déconnecté'}</td>
    <td><button onclick="post('/api/${d.name}/reconnect')">Reconnecter</button></td>
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
        self.send(200, "{}")


if __name__ == "__main__":
    # ponytail: pas d'auth, LAN uniquement. Ajouter un reverse proxy avec auth si exposé.
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
