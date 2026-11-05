#!/usr/bin/env python3
"""VNC for the Omarchy bar: turn wayvnc on and off, see who's viewing the
screen, drop a viewer, and let guests in and out.

With no arguments (or `status`) prints one JSON object for BarWidget.qml.
Every other subcommand is an action behind the panel:

  on | off | toggle             start or stop the VNC server (off shuts guests out too)
  disconnect <client-id>        drop one viewer
  announce <address>            notify that a viewer connected from <address>
  guest <name> on|off|toggle    let a guest in, or shut them out and cut their session
  gate                          the guest door itself; `guest <name> on` starts it

`on` runs the same wayvnc you would start by hand, which takes its address,
port and password from ~/.config/wayvnc/config. It runs until `off` or the
end of the session; nothing starts it on its own. A wayvnc started by hand
counts as on too, and `off` stops it through its control socket.

Guests are people whose PCs are on the tailnet but who only get in while you
say so. ~/.config/wayvnc/guests.json names them and their Tailscale addresses.
The tailnet policy lets a guest reach this PC on the guest port (5901) and
nothing else, so wayvnc's own port stays closed to them. While someone is let
in, `gate` listens on the guest port and passes their connections through to
wayvnc; it hangs up on anyone else. Who's let in is kept in $XDG_RUNTIME_DIR,
so a logout or reboot shuts everyone out again. Guests log in with the same
username and password as you.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import time

CONFIG = os.path.expanduser("~/.config/wayvnc/config")
GUESTS = os.path.expanduser("~/.config/wayvnc/guests.json")
RUNTIME = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
LOG = os.path.join(RUNTIME, "omarchy-vnc.log")
LET_IN = os.path.join(RUNTIME, "omarchy-vnc.guests.json")   # names let in right now
GATE_STATE = os.path.join(RUNTIME, "omarchy-vnc.gate.json")  # the gate's pid and live sessions
GATE_LOG = os.path.join(RUNTIME, "omarchy-vnc.gate.log")
WAYVNC = ["wayvnc", "--gpu", "--max-fps=60"]


def run(*cmd, timeout=5):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return None


def notify(title, body, urgency="normal"):
    subprocess.run(["notify-send", "-a", "VNC", "-u", urgency, "-i", "preferences-desktop-remote-desktop",
                    title, body], check=False)


def launcher():
    # uwsm-app gives the process its own scope, so it outlives this script and the shell.
    return ["uwsm-app", "--"] if shutil.which("uwsm-app") else []


def read_config():
    cfg = {}
    try:
        with open(CONFIG) as f:
            for line in f:
                key, sep, value = line.partition("=")
                if sep and not key.lstrip().startswith("#"):
                    cfg[key.strip()] = value.strip()
    except OSError:
        pass
    return cfg


def read_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_json(path, data):
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, path)


def read_guests():
    """(guest port, {name: Tailscale address}) from guests.json."""
    data = read_json(GUESTS, {})
    try:
        return int(data.get("port", 5901)), {str(k): str(v) for k, v in (data.get("guests") or {}).items()}
    except (AttributeError, TypeError, ValueError):
        return 5901, {}


def let_in():
    """Names let in, as written; only meaningful while a gate runs (see allowed())."""
    names = read_json(LET_IN, [])
    return {str(n) for n in names} if isinstance(names, list) else set()


def set_let_in(names):
    if names:
        write_json(LET_IN, sorted(names))
        return
    try:
        os.remove(LET_IN)
    except FileNotFoundError:
        pass


def gate_state():
    """The running gate's {"pid", "port", "sessions": {name: count}}, or None."""
    state = read_json(GATE_STATE, None)
    if not isinstance(state, dict):
        return None
    try:
        with open(f"/proc/{int(state.get('pid'))}/cmdline", "rb") as f:
            alive = b"gate" in f.read().split(b"\0")
    except (OSError, TypeError, ValueError):
        alive = False
    return state if alive else None


def allowed(gate):
    # Nobody is in without a gate to let them in, whatever the file says.
    return let_in() if gate else set()


def viewers():
    """Connected clients, or None when no wayvnc answers on its control socket."""
    r = run("wayvncctl", "--json", "client-list")
    if not r or r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout or "[]")
    except ValueError:
        return None


def plain(address):
    return (address or "").removeprefix("::ffff:")  # IPv4 peers can come IPv6-mapped


def tailnet():
    """{Tailscale address: (host name, online)} for this PC and its peers."""
    r = run("tailscale", "status", "--json")
    try:
        data = json.loads(r.stdout) if r and r.stdout else {}
    except ValueError:
        return {}
    nodes = {}
    me = data.get("Self") or {}
    for node in [me, *(data.get("Peer") or {}).values()]:
        for ip in node.get("TailscaleIPs") or []:
            nodes[ip] = (node.get("HostName", ""), node is me or bool(node.get("Online")))
    return nodes


def who(address, cfg, guests, names, gate):
    """(name, address) of a wayvnc client.

    Guests come in through the gate, so wayvnc sees this PC's own address;
    the gate knows who is behind it.
    """
    address = plain(address)
    inside = [n for n, count in ((gate or {}).get("sessions") or {}).items() if count]
    if inside and address == cfg.get("address"):
        return ", ".join(inside), ", ".join(guests.get(n, "") for n in inside)
    return names.get(address, ""), address


def last_error(path=LOG):
    """The latest complaint in a log, e.g. wayvnc failing to bind the Tailscale address."""
    try:
        with open(path) as f:
            errors = [line.strip() for line in f if line.startswith("ERROR")]
    except OSError:
        return ""
    # "ERROR: ../src/main.c: 123: Failed to …" → "Failed to …"
    return re.sub(r"^ERROR: .*?: \d+: ", "", errors[-1]) if errors else ""


def status():
    cfg = read_config()
    clients = viewers()
    port, guests = read_guests()
    gate = gate_state()
    inn = allowed(gate)
    sessions = (gate or {}).get("sessions") or {}
    nodes = tailnet() if clients or guests else {}
    names = {ip: name for ip, (name, _) in nodes.items()}
    shown = []
    for c in clients or []:
        name, address = who(c.get("address"), cfg, guests, names, gate)
        shown.append({"id": str(c.get("id", "")), "address": address, "name": name})
    print(json.dumps({
        "time": int(time.time()),
        "running": clients is not None,
        "listen": f"{cfg.get('address', '0.0.0.0')}:{cfg.get('port', '5900')}",
        "username": cfg.get("username", ""),
        "auth": cfg.get("enable_auth") == "true",
        "viewers": shown,
        "guestPort": port,
        "guests": [{"name": n, "address": ip, "allowed": n in inn, "viewing": int(sessions.get(n, 0)),
                    "online": nodes.get(ip, ("", False))[1]} for n, ip in sorted(guests.items())],
    }))
    return 0


def displays():
    """(name, powered on) for each display Hyprland has, or None if it can't say."""
    r = run("hyprctl", "monitors", "-j")
    try:
        return [(m.get("name"), m.get("dpmsStatus")) for m in json.loads(r.stdout)] if r and r.returncode == 0 else None
    except ValueError:
        return None


def wake_display():
    """Light the display and wait for it to settle before wayvnc starts.

    The HDMI monitor drops off the bus while it's powered off (the lock screen
    does that), and waking it can bounce the connector: unplugged, plugged in
    again. Hyprland 0.56 crashes if that happens while wayvnc is capturing, so
    wake it here, before wayvnc exists. extras/vnc.lua (see the README) keeps
    it lit from then on.
    """
    state = displays()
    if state and all(on for _, on in state):
        return
    run("omarchy-brightness-display", "on")
    last, since = None, time.monotonic()
    deadline = since + 15
    while time.monotonic() < deadline:
        time.sleep(0.25)
        state = displays()
        if state != last:
            last, since = state, time.monotonic()
        elif state and all(on for _, on in state) and time.monotonic() - since >= 4:
            return


def turn_on():
    if viewers() is not None:
        return 0
    wake_display()
    with open(LOG, "w") as log:
        subprocess.Popen(launcher() + WAYVNC, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                         start_new_session=True)
    # wayvnc answers on its control socket once it's listening.
    for _ in range(16):
        time.sleep(0.25)
        if viewers() is not None:
            return 0
    notify("VNC didn't start", last_error() or f"Is Tailscale up? {LOG} has the details.", "critical")
    return 1


def turn_off():
    # Guests first: the gate hangs up on them and leaves within a second.
    set_let_in(set())
    if viewers() is not None:
        run("wayvncctl", "wayvnc-exit")
    for _ in range(8):
        r = run("pgrep", "-x", "wayvnc")
        if not r or r.returncode != 0:
            return 0
        time.sleep(0.25)
    run("pkill", "-x", "wayvnc")
    return 0


def announce(address):
    _, guests = read_guests()
    names = {ip: name for ip, (name, _) in tailnet().items()}
    name, shown = who(address, read_config(), guests, names, gate_state())
    notify(f"{name or shown} is viewing your screen",
           f"VNC session from {shown}. Drop it from the VNC icon in the bar.")
    return 0


def start_gate():
    with open(GATE_LOG, "a") as log:
        subprocess.Popen(launcher() + [sys.executable, os.path.abspath(__file__), "gate"],
                         stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)


def let_guest_in(name):
    # A guest needs a server to come into.
    if turn_on() != 0:
        return 1
    set_let_in(allowed(gate_state()) | {name})
    # Done once a gate says it's open for them. Start one if none is running,
    # including when the last one closed just now because nobody was let in.
    started = None
    deadline = time.monotonic() + 6
    while time.monotonic() < deadline:
        gate = gate_state()
        if gate and name in (gate.get("open_for") or []):
            return 0
        if not gate and (started is None or time.monotonic() - started > 2):
            start_gate()
            started = time.monotonic()
        time.sleep(0.25)
    set_let_in(allowed(gate_state()) - {name})
    notify(f"Couldn't let {name} in", f"The guest door didn't open. {GATE_LOG} has the details.", "critical")
    return 1


def shut_out(name):
    set_let_in(allowed(gate_state()) - {name})
    # The gate checks every second; wait until their session is gone.
    for _ in range(12):
        gate = gate_state()
        if not gate or not (gate.get("sessions") or {}).get(name):
            return 0
        time.sleep(0.25)
    return 1


def guest(name, action):
    _, guests = read_guests()
    match = next((g for g in guests if g.lower() == name.lower()), None)
    if not match:
        print(f"No guest called {name} in {GUESTS}", file=sys.stderr)
        return 2
    if action == "toggle":
        action = "off" if match in allowed(gate_state()) else "on"
    if action == "on":
        return let_guest_in(match)
    if action == "off":
        return shut_out(match)
    print(__doc__, file=sys.stderr)
    return 2


def gate():
    """The guest door: pass guests who are let in through to wayvnc, hang up on
    everyone else, cut a guest's sessions once they're shut out, and leave
    when nobody is let in any more."""
    import asyncio

    cfg = read_config()
    host, upstream = cfg.get("address", "127.0.0.1"), int(cfg.get("port", 5900))
    port, _ = read_guests()
    sessions = {}  # name → {(guest side, wayvnc side), …}
    open_for = let_in()
    closing = False

    def log(message):
        print(time.strftime("%F %T"), message, flush=True)

    def save():
        if closing:  # sessions winding down mustn't bring the state back
            return
        write_json(GATE_STATE, {"pid": os.getpid(), "port": port, "open_for": sorted(open_for),
                                "sessions": {n: len(s) for n, s in sessions.items() if s}})

    def guest_at(address):
        _, guests = read_guests()
        inn = let_in()
        return next((n for n, ip in guests.items() if ip == address and n in inn), None)

    def hang_up(pairs):
        for pair in list(pairs):
            for writer in pair:
                writer.close()

    async def pipe(reader, writer):
        try:
            while data := await reader.read(1 << 16):
                writer.write(data)
                await writer.drain()
        except (ConnectionError, OSError):
            pass
        finally:
            writer.close()  # ends the other direction too

    async def handle(reader, writer):
        address = plain((writer.get_extra_info("peername") or ("",))[0])
        name = guest_at(address)
        if not name:
            log(f"hung up on {address}: not a guest who's let in")
            writer.close()
            return
        try:
            up_reader, up_writer = await asyncio.wait_for(asyncio.open_connection(host, upstream), 5)
        except (OSError, asyncio.TimeoutError) as e:
            log(f"{name}: wayvnc didn't answer on {host}:{upstream} ({e})")
            writer.close()
            return
        pair = (writer, up_writer)
        sessions.setdefault(name, set()).add(pair)
        save()
        log(f"{name} connected from {address}")
        try:
            await asyncio.gather(pipe(reader, up_writer), pipe(up_reader, writer))
        finally:
            sessions[name].discard(pair)
            save()
            log(f"{name} disconnected")

    def forget():
        state = read_json(GATE_STATE, None)
        if isinstance(state, dict) and state.get("pid") == os.getpid():
            os.remove(GATE_STATE)

    async def serve():
        nonlocal open_for, closing
        try:
            server = await asyncio.start_server(handle, host, port)
        except OSError as e:
            log(f"ERROR: can't listen on {host}:{port}: {e}")
            return 1
        save()
        log(f"open on {host}:{port} for {', '.join(sorted(open_for)) or 'nobody'}, passing through to {host}:{upstream}")
        while open_for:
            await asyncio.sleep(0.5)
            inn = let_in()
            for name, pairs in sessions.items():
                if name not in inn and pairs:
                    log(f"{name} shut out: cutting the session")
                    hang_up(pairs)
            if inn != open_for:
                open_for = inn
                save()
        # Free the port before the state goes, so whoever sees no gate can start one.
        server.close()
        closing = True
        forget()
        for pairs in sessions.values():
            hang_up(pairs)
        await asyncio.sleep(0.2)  # let the pipes wind down
        log("closed: nobody is let in")
        return 0

    try:
        return asyncio.run(serve())
    finally:
        forget()


def main(argv):
    cmd = argv[0] if argv else "status"
    args = argv[1:]
    if cmd == "status":
        return status()
    if cmd == "on":
        return turn_on()
    if cmd == "off":
        return turn_off()
    if cmd == "toggle":
        return turn_off() if viewers() is not None else turn_on()
    if cmd == "disconnect" and len(args) == 1:
        r = run("wayvncctl", "client-disconnect", args[0])
        return 0 if r and r.returncode == 0 else 1
    if cmd == "announce" and len(args) == 1:
        return announce(args[0])
    if cmd == "guest" and len(args) == 2:
        return guest(*args)
    if cmd == "gate":
        return gate()
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
