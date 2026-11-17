from panel import find, parse_connected

assert parse_connected("b true\n")
assert not parse_connected("b false\n")
assert not parse_connected("")  # unknown device / adapter: busctl prints nothing on stdout

devs = [{"name": "bose", "mac": "AA", "modes": ["bt"]}, {"name": "ampli", "sink": "x", "modes": ["local"]}]
assert find(devs, "bose")["mac"] == "AA"
for bad in ("nope", "ampli", "bose;reboot", "../etc"):
    try:
        find(devs, bad)
        raise AssertionError(bad)
    except KeyError:
        pass
print("ok")

import json, os, tempfile
from panel import sources
with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
    json.dump({"providers": {"a1": {"domain": "spotify", "enabled": True},
                             "b2": {"domain": "deezer", "enabled": False}}}, f)
assert sources(f.name) == {"spotify": True, "deezer": False}
os.unlink(f.name)
assert sources("/nope.json") == {"spotify": None, "deezer": None}
print("ok sources")
