# Octopus Raspberry Pi

Music Assistant (Spotify/Deezer, Cast, groupes) + squeezelite par sortie BT/jack + mini panel BT.

1. Pour chaque enceinte BT (BT intégré, un seul contrôleur) : `bluetoothctl` → `scan on` → `pair <MAC>` → `trust <MAC>`.
2. Remplir `devices.json` (MAC, adapter). Pour l'ampli, mettre dans `sink` le préfixe vu dans `pactl list short sinks` (ex. `alsa_output.platform-...`).
3. `sudo ./install.sh`, puis reboot la 1re fois. Raspberry Pi OS Lite **64-bit**, Ethernet conseillé.
4. MA `http://octopus.local:8095` : providers Spotify, Deezer (token ARL : cookie `arl` de deezer.com connecté), Chromecast, Squeezelite. Créer un Universal group « Tout l'appart » **par combinaison** Klipsch/HomeMini (version BT ou Cast), sinon une même enceinte joue en double.
5. Calibrer : métronome sur le groupe, régler « sync adjust » de chaque player squeezelite jusqu'à ce qu'il s'aligne sur Cast.
6. Panel `http://octopus.local:8080` : état BT, reconnecter, bascule cast/bt.

Test : `python3 test_panel.py`.
