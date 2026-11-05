# VNC for Omarchy

An [Omarchy](https://omarchy.org) bar widget for [wayvnc](https://github.com/any1/wayvnc) screen sharing. It turns VNC on and off, shows who's viewing your screen, lets you drop a viewer, and gives each guest their own switch to let them in or shut them out.

## What it does

- **Bar:** a remote-desktop icon that lights up while someone is viewing. Middle-click turns VNC on or off.
- **Panel** (left click): the server switch, everyone viewing right now (named from Tailscale where possible) with a button to drop each one, and a switch per guest.
- **Notifications** when a viewer connects (can be turned off in the widget settings).
- A warning if wayvnc has no password set.

`on` starts the same wayvnc you'd start by hand (`wayvnc --gpu --max-fps=60`), taking its address, port and login from `~/.config/wayvnc/config`. It runs until you switch it off or log out; nothing starts it on its own.

## Guests

Guests are people whose PCs are on your tailnet but who should only get in while you say so. They never reach wayvnc's own port (5900). While a guest's switch is on, a small gate listens on a separate guest port (5901), passes that guest's connections through to wayvnc, and hangs up on anyone else. Switch them off and their session is cut within a second. Switching VNC off shuts everyone out. Who's let in is kept in `$XDG_RUNTIME_DIR`, so a logout or reboot shuts everyone out too. Guests log in with the same wayvnc username and password as you, because wayvnc has only one login.

1. List guests in `~/.config/wayvnc/guests.json` with their Tailscale address (see [`examples/guests.json`](examples/guests.json)).
2. In your tailnet policy, give each guest the guest port on your PC and nothing else, for example:

   ```hujson
   "hosts": { "my-pc": "100.64.0.1" },
   "grants": [
     { "src": ["guest-pc"], "dst": ["my-pc"], "ip": ["tcp:5901"] },
   ],
   ```

3. The guest connects their VNC viewer to `<your Tailscale IP>::5901`.

## Install

```bash
omarchy plugin add https://github.com/YassineSawahi/omarchy-vnc.git --enable
```

Needs `wayvnc`, and `tailscale` for viewer names and guests. A minimal `~/.config/wayvnc/config` listening on your Tailscale address:

```ini
address=100.64.0.1
port=5900
enable_auth=true
username=me
password=change-me
```

## Controls

| Action | Does |
|---|---|
| Left click | Open or close the panel |
| Middle click | Turn VNC on or off |
| Right click | Read the state again |
| `omarchy-shell io.github.yassinesawahi.vnc togglePower` | Turn VNC on or off (also `turnOn`, `turnOff`, `toggle`, `refresh`, `close`) |
| `omarchy-shell io.github.yassinesawahi.vnc toggleGuest <name>` | Let a guest in or shut them out |

The helper works on its own too: `vnc.py on|off|toggle`, `vnc.py guest <name> on|off|toggle`, `vnc.py disconnect <client-id>`.

With [omarchy-phone](https://github.com/YassineSawahi/omarchy-phone) installed too, your phone gets a "VNC on/off" button (KDE Connect's Run command) that switches this and tells you how it went.

## Optional: keep the display lit while VNC runs

Some monitors (HDMI ones especially) drop off the bus when the lock screen powers them off. A VNC viewer waking one makes the connector bounce, and Hyprland 0.56 crashed when that happened mid-capture. [`extras/`](extras) has the workaround:

- `vnc.lua`: copy to `~/.config/hypr/vnc.lua` and add `require("hypr.vnc")` to `~/.config/hypr/hyprland.lua`. While wayvnc runs, it skips requests to power the display off.
- `vnc-wake` + `vnc-wake.service`: copy the script to `~/.local/bin/` and the unit to `~/.config/systemd/user/`, then `systemctl --user enable --now vnc-wake`. It wakes the display when wayvnc starts, and powers it off again when wayvnc stops while the session is locked.

## License

MIT
