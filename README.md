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

## How it works

Everything runs on this PC. Viewers reach it over [Tailscale](https://tailscale.com), so it works the same at home and away, and nothing is opened on your router or to the internet.

- **wayvnc** is the server. It listens on the address in `~/.config/wayvnc/config`, your PC's Tailscale address, so only devices on your tailnet can reach port 5900. Your tailnet policy decides which ones.
- **`vnc.py`** is the helper behind the panel. It starts wayvnc, and talks to it through `wayvncctl` on wayvnc's local control socket: who's connected, drop one, shut down. It asks `tailscale status` for the device name behind each viewer's address.
- **The widget** runs `vnc.py status` on a timer, and keeps `wayvncctl event-receive` open so a viewer connecting or leaving shows up at once (and brings the notification).
- **The guest door** is `vnc.py gate`. It runs only while at least one guest is let in, listening on the guest port (5901) on the same address. It looks at where each connection comes from: a guest who's let in is piped through to wayvnc, anyone else is hung up on. It re-reads the let-in list in `$XDG_RUNTIME_DIR` twice a second, cuts a guest's session as soon as their switch goes off, and exits when nobody is let in. Because guests come through the door, wayvnc sees this PC's own address for them; the door tells the panel who's behind it.
- **From your phone:** with [omarchy-phone](https://github.com/YassineSawahi/omarchy-phone), KDE Connect's "VNC on/off" button runs the same switch on this PC and sends the result back to the phone.

```text
 YOUR DEVICES                              THIS PC
 VNC viewer ----- Tailscale, port 5900 ---> wayvnc (on the Tailscale address)
                                              ^            ^
 A GUEST'S PC                                 |            | wayvncctl
 VNC viewer ----- Tailscale, port 5901 ---> guest door     | (local socket)
                  (only while a guest       (vnc.py gate)  |
                   is let in)                            vnc.py <-- bar widget
```

**Locked by default.** Without a password, anyone who can reach wayvnc's port, every other account on this PC included, would see and drive your desktop, so the panel only starts wayvnc with authentication on and the config private (see Install). The helper's own files (its log, who's let in) live in `$XDG_RUNTIME_DIR`, never in `/tmp`.

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

It holds your password, so keep it yours alone: `chmod 600 ~/.config/wayvnc/config`. The panel won't start wayvnc without `enable_auth=true` and a password, or while other accounts can read that file.

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

## Remove

```bash
python3 ~/.config/omarchy/plugins/io.github.yassinesawahi.vnc/vnc.py off   # stop wayvnc and shut every guest out
omarchy plugin remove io.github.yassinesawahi.vnc
```

If you installed the extras: `systemctl --user disable --now vnc-wake`, delete `~/.local/bin/vnc-wake` and `~/.config/systemd/user/vnc-wake.service`, and remove `require("hypr.vnc")` from `~/.config/hypr/hyprland.lua` along with `~/.config/hypr/vnc.lua`. Your `~/.config/wayvnc/config` and `guests.json` stay; drop the guests' grants from your tailnet policy.

## License

MIT
