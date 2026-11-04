#!/usr/bin/env python3
"""pin-gate: trade a 6-digit PIN for the relay's full login key.

Sits next to the Tidal_Echo relay without touching it. nginx sends exactly
POST /relay/pin here (127.0.0.1:3012); everything else under /relay/ still goes
to the relay. The full key stays in relay.env and is only ever read, never changed.

A 6-digit PIN is guessable on its own, so failures are capped *globally*
(not per IP, so spreading guesses over many machines doesn't help):
  - 5 wrong PINs within 15 minutes  -> locked until the oldest of them is 15 min old
  - 20 wrong PINs within 24 hours   -> locked until the oldest of them is 24 h old
That is at most 20 guesses a day, so walking all 1,000,000 PINs would take over
130 years. The failure log survives restarts. Requests are handled one at a time,
and every check costs a 200k-round PBKDF2, so the PIN itself is never stored.

Files (all chmod 600, owned by the relay user):
  pin.env        PIN_SALT / PIN_HASH / PIN_ITER   (written by pin-setup.sh)
  pin-state.json timestamps of recent wrong PINs
Standard library only.
"""
import hashlib, hmac, json, os, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer

BASE = os.path.dirname(os.path.abspath(__file__))
RELAY_ENV = os.path.join(BASE, "relay.env")
PIN_ENV = os.path.join(BASE, "pin.env")
STATE = os.path.join(BASE, "pin-state.json")
HOST, PORT = "127.0.0.1", int(os.environ.get("PIN_GATE_PORT", "3012"))
SHORT_WIN, SHORT_MAX = 15 * 60, 5
LONG_WIN, LONG_MAX = 24 * 3600, 20


def read_env(path):
    out = {}
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    out[k.strip()] = v.strip()
    except FileNotFoundError:
        pass
    return out


def load_fails(now):
    try:
        with open(STATE, encoding="utf-8") as f:
            ts = [float(t) for t in json.load(f).get("fails", [])]
    except (FileNotFoundError, ValueError, TypeError, AttributeError):
        ts = []
    return sorted(t for t in ts if now - t < LONG_WIN)


def save_fails(ts):
    tmp = STATE + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump({"fails": ts}, f)
    os.replace(tmp, STATE)


def locked_for(ts, now):
    """Seconds until another attempt is allowed, or 0."""
    recent = [t for t in ts if now - t < SHORT_WIN]
    wait = 0.0
    if len(recent) >= SHORT_MAX:
        wait = max(wait, recent[-SHORT_MAX] + SHORT_WIN - now)
    if len(ts) >= LONG_MAX:
        wait = max(wait, ts[-LONG_MAX] + LONG_WIN - now)
    return max(0.0, wait)


class Handler(BaseHTTPRequestHandler):
    server_version = "pin-gate"
    sys_version = ""

    def log_message(self, fmt, *args):  # journald gets one short line per request
        sys.stdout.write("%s %s\n" % (self.headers.get("X-Real-IP") or self.client_address[0], fmt % args))
        sys.stdout.flush()

    def reply(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.reply(405, {"error": "POST only"})

    def do_POST(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = 0
        if n <= 0 or n > 256:
            return self.reply(400, {"error": "bad request"})
        try:
            pin = str(json.loads(self.rfile.read(n)).get("pin", ""))
        except (ValueError, AttributeError):
            return self.reply(400, {"error": "bad request"})
        if not (len(pin) == 6 and pin.isdigit() and pin.isascii()):
            return self.reply(400, {"error": "need 6 digits"})

        cfg = read_env(PIN_ENV)
        secret = read_env(RELAY_ENV).get("RELAY_SECRET", "")
        if not (cfg.get("PIN_SALT") and cfg.get("PIN_HASH") and secret):
            return self.reply(503, {"error": "pin not set up"})

        now = time.time()
        fails = load_fails(now)
        wait = locked_for(fails, now)
        if wait > 0:
            return self.reply(429, {"error": "too many tries", "retry_after_min": int(wait // 60) + 1})

        got = hashlib.pbkdf2_hmac("sha256", pin.encode(), bytes.fromhex(cfg["PIN_SALT"]),
                                  int(cfg.get("PIN_ITER", "200000")))
        if hmac.compare_digest(got.hex(), cfg["PIN_HASH"]):
            if fails:
                save_fails([])
            return self.reply(200, {"token": secret})

        fails.append(now)
        save_fails(fails)
        left = locked_for(fails, now)
        out = {"error": "wrong pin"}
        if left > 0:
            out["retry_after_min"] = int(left // 60) + 1
        return self.reply(401, out)


if __name__ == "__main__":
    os.umask(0o077)
    print("pin-gate listening on %s:%d" % (HOST, PORT), flush=True)
    HTTPServer((HOST, PORT), Handler).serve_forever()
