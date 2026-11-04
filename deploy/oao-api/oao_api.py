#!/usr/bin/env python3
"""oao-api: the small extras the Aether PWA needs that the Tidal_Echo relay doesn't have.

Runs next to the relay (never modifies it) on 127.0.0.1:3013; nginx sends only these
paths here, everything else under /relay/ still goes to the relay:

  GET  /relay/app/kv/<name>      shared JSON blobs (calendar, events, calendar_orion)
  PUT  /relay/app/kv/<name>        so phone, iPad and Orion see the same calendar
  GET  /relay/app/usage          Claude plan usage (5-hour / weekly), read with the
                                   server Claude Code's own login, cached 2 minutes
  GET  /relay/app/model          which model / effort the server Orion is set to
  POST /relay/app/model          {"model": "...", "effort": "...", "restart": bool}
                                   model -> types "/model <id>" into tmux session orion
                                   effort -> ~/.claude/settings.json effortLevel
                                             (Claude Code reads it when it starts)
                                   restart -> kill + start-orion.sh

Auth: same key as the relay (RELAY_SECRET in relay.env), as "Authorization: Bearer"
or ?token=. Standard library only. Requests are handled one at a time.
"""
import hmac
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

HOME = Path(os.environ.get("HOME", "/home/ubuntu"))
BASE = Path(__file__).resolve().parent
KV_DIR = BASE / "kv"
RELAY_ENV = HOME / "companion-relay" / "relay.env"
CREDS = HOME / ".claude" / ".credentials.json"
CC_SETTINGS = HOME / ".claude" / "settings.json"
STATE = BASE / "state.json"
START_ORION = HOME / "orion" / "start-orion.sh"
TMUX_SESSION = "orion"
HOST, PORT = "127.0.0.1", int(os.environ.get("OAO_API_PORT", "3013"))

KV_NAMES = {"calendar", "events", "calendar_orion"}
KV_MAX = 512 * 1024
USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
USAGE_TTL = 120
MODELS = {  # what the picker offers; ids are what /model accepts
    "claude-opus-5-5": "Opus 5.5",
    "claude-fable-5-1": "Fable 5.1",
    "claude-sonnet-5-5": "Sonnet 5.5",
    "claude-haiku-5-5": "Haiku 5.5",
}
EFFORTS = ["low", "medium", "high", "xhigh", "max"]

_usage_cache = {"at": 0.0, "body": None}


def read_env(path):
    out = {}
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                k, v = line.split("=", 1)
                out[k.strip()] = v.strip()
    except OSError:
        pass
    return out


def read_json(path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


def write_json(path, data, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)


def tmux(*args):
    return subprocess.run(["tmux", *args], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode


# ---- usage --------------------------------------------------------------------

def fetch_usage():
    now = time.time()
    if _usage_cache["body"] is not None and now - _usage_cache["at"] < USAGE_TTL:
        return _usage_cache["body"]
    creds = read_json(CREDS, {}).get("claudeAiOauth") or {}
    token = creds.get("accessToken")
    if not token:
        return {"ok": False, "error": "no_login", "message": "服务器上的 Claude Code 还没登录"}
    exp = creds.get("expiresAt")
    if isinstance(exp, (int, float)) and exp / 1000 < now:
        return {"ok": False, "error": "token_expired",
                "message": "登录凭证过期了，等 Orion 下次醒来会自己续上"}
    req = urllib.request.Request(USAGE_URL, headers={
        "Authorization": f"Bearer {token}",
        "anthropic-beta": "oauth-2025-04-20",
        "Content-Type": "application/json",
        "User-Agent": "oao-api (Aether usage panel)",
    })
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            data = json.load(r)
    except urllib.error.HTTPError as e:
        return {"ok": False, "error": f"http_{e.code}", "message": f"额度接口返回 {e.code}"}
    except Exception as e:
        return {"ok": False, "error": "fetch_failed", "message": str(e)[:200]}
    body = {"ok": True, "fetched_at": int(now * 1000), "data": data}
    _usage_cache.update(at=now, body=body)
    return body


# ---- model ----------------------------------------------------------------------

def model_state():
    s = read_json(CC_SETTINGS, {})
    st = read_json(STATE, {})
    model = st.get("model") or s.get("model") or ""
    effort = s.get("effortLevel") or st.get("effort") or ""
    return {
        "ok": True,
        "model": model,
        "label": MODELS.get(model, model or "默认"),
        "effort": effort,
        "effort_pending": bool(st.get("effort_pending")),
        "models": [{"id": k, "label": v} for k, v in MODELS.items()],
        "efforts": EFFORTS,
        "running": tmux("has-session", "-t", TMUX_SESSION) == 0,
    }


def set_model(body):
    st = read_json(STATE, {})
    msgs = []
    model = body.get("model")
    effort = body.get("effort")
    if model:
        if model not in MODELS:
            return 400, {"ok": False, "error": "unknown model"}
        s = read_json(CC_SETTINGS, {})
        s["model"] = model
        write_json(CC_SETTINGS, s, 0o644)
        st["model"] = model
        if tmux("has-session", "-t", TMUX_SESSION) == 0:
            tmux("send-keys", "-t", TMUX_SESSION, "-l", f"/model {model}")
            time.sleep(0.6)
            tmux("send-keys", "-t", TMUX_SESSION, "Enter")
            msgs.append("model_now")
        else:
            msgs.append("model_next_start")
    if effort:
        if effort not in EFFORTS:
            return 400, {"ok": False, "error": "unknown effort"}
        s = read_json(CC_SETTINGS, {})
        if s.get("effortLevel") != effort:
            s["effortLevel"] = effort
            write_json(CC_SETTINGS, s, 0o644)
            st["effort_pending"] = True
        st["effort"] = effort
        msgs.append("effort_next_start")
    if body.get("restart"):
        tmux("kill-session", "-t", TMUX_SESSION)
        time.sleep(1)
        subprocess.Popen([str(START_ORION)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
        st["effort_pending"] = False
        msgs.append("restarted")
    write_json(STATE, st)
    out = model_state()
    out["done"] = msgs
    return 200, out


# ---- http -------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    server_version = "oao-api"
    sys_version = ""

    def log_message(self, fmt, *args):
        sys.stdout.write("%s %s\n" % (self.headers.get("X-Real-IP") or self.client_address[0], fmt % args))
        sys.stdout.flush()

    def reply(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def authed(self):
        secret = read_env(RELAY_ENV).get("RELAY_SECRET", "")
        if not secret:
            return False
        h = self.headers.get("Authorization", "")
        tok = h[7:].strip() if h.startswith("Bearer ") else ""
        if not tok:
            tok = (parse_qs(urlparse(self.path).query).get("token") or [""])[0]
        return bool(tok) and hmac.compare_digest(tok, secret)

    def route(self):
        p = urlparse(self.path).path
        for prefix in ("/relay", ""):
            if p.startswith(prefix + "/app/"):
                return p[len(prefix) + 5:]
        return p.lstrip("/")

    def body_json(self, limit):
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = 0
        if n <= 0 or n > limit:
            return None
        try:
            return json.loads(self.rfile.read(n))
        except ValueError:
            return None

    def do_GET(self):
        if not self.authed():
            return self.reply(401, {"detail": "unauthorized"})
        r = self.route()
        m = re.fullmatch(r"kv/([a-z_]+)", r)
        if m:
            name = m.group(1)
            if name not in KV_NAMES:
                return self.reply(404, {"detail": "unknown kv"})
            return self.reply(200, read_json(KV_DIR / f"{name}.json", None))
        if r == "usage":
            return self.reply(200, fetch_usage())
        if r == "model":
            return self.reply(200, model_state())
        return self.reply(404, {"detail": "not found"})

    def do_PUT(self):
        if not self.authed():
            return self.reply(401, {"detail": "unauthorized"})
        m = re.fullmatch(r"kv/([a-z_]+)", self.route())
        # calendar_orion is Orion's own shelf: only his MCP tool writes it
        if not m or m.group(1) not in KV_NAMES or m.group(1) == "calendar_orion":
            return self.reply(404, {"detail": "not found"})
        data = self.body_json(KV_MAX)
        if data is None:
            return self.reply(400, {"detail": "bad body"})
        write_json(KV_DIR / f"{m.group(1)}.json", data)
        return self.reply(200, {"ok": True})

    def do_POST(self):
        if not self.authed():
            return self.reply(401, {"detail": "unauthorized"})
        if self.route() != "model":
            return self.reply(404, {"detail": "not found"})
        body = self.body_json(4096)
        if not isinstance(body, dict):
            return self.reply(400, {"detail": "bad body"})
        code, out = set_model(body)
        return self.reply(code, out)


if __name__ == "__main__":
    os.umask(0o077)
    KV_DIR.mkdir(parents=True, exist_ok=True)
    print("oao-api listening on %s:%d" % (HOST, PORT), flush=True)
    HTTPServer((HOST, PORT), Handler).serve_forever()
