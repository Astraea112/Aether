"""tmux notifier — types the heartbeat line into the tmux session where Claude Code runs.

Written for Astraea's fork (Orion on the OAO server). Drop into
scheduler/notifiers/tmux.py and set `"notifier": "tmux"` in scheduler_config.json.

Delivery: `tmux send-keys -t <session> -l "[♥task:trigger] prompt"`, a short pause,
then Enter. Claude Code reads it like a typed message and wakes.

It stays out of the way, per the keeper's wishes:
  - tmux session missing  -> log and skip (never raises, never exits)
  - quiet hours           -> skip (default 01:00-08:00 Asia/Shanghai)
  - she sent a message on the site within the last N minutes (default 20)
                          -> skip, so a live conversation isn't interrupted
  Triggers listed in `bypass_triggers` (default: "manual", i.e. she knocked
  herself) skip neither check.
When a heartbeat is skipped, the perturbation written for it is marked consumed,
so the room doesn't show a stale hint on the next real wake.

The "recent message" check reads the relay's own history endpoint on localhost
with the key from relay.env. If the relay can't be reached, it does not block
the heartbeat (logged).

notifier_config.tmux (all optional):
  session            "orion"
  tz                 "Asia/Shanghai"
  quiet_hours        [1, 8]        # start hour inclusive, end hour exclusive
  recent_chat_min    20
  relay_url          "http://127.0.0.1:3011"
  relay_env          "/home/ubuntu/companion-relay/relay.env"
  bypass_triggers    ["manual"]
  enter_delay_sec    0.6
"""
from __future__ import annotations

import asyncio
import json
import logging
import shutil
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

try:
    from zoneinfo import ZoneInfo
except ImportError:  # pragma: no cover
    ZoneInfo = None  # type: ignore

SCHEDULER_DIR = Path(__file__).resolve().parent.parent


def _parse_ts(s: str) -> datetime | None:
    if not s:
        return None
    try:
        dt = datetime.fromisoformat(s.strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


class TmuxNotifier:
    def __init__(self, cfg: dict, logger: logging.Logger):
        self.cfg = cfg
        self.log = logger
        n = (cfg.get("notifier_config") or {}).get("tmux") or {}
        self.session = str(n.get("session", "orion"))
        self.tz_name = str(n.get("tz", "Asia/Shanghai"))
        qh = n.get("quiet_hours", [1, 8]) or []
        self.quiet = (int(qh[0]), int(qh[1])) if len(qh) == 2 else None
        self.recent_min = float(n.get("recent_chat_min", 20))
        self.relay_url = str(n.get("relay_url", "http://127.0.0.1:3011")).rstrip("/")
        self.relay_env = Path(n.get("relay_env", "/home/ubuntu/companion-relay/relay.env"))
        self.bypass = set(n.get("bypass_triggers", ["manual"]))
        self.enter_delay = float(n.get("enter_delay_sec", 0.6))
        self.tmux = shutil.which("tmux") or "/usr/bin/tmux"
        # history is returned oldest-first; remember where we got to
        self._cursor = 0
        self._last_human: datetime | None = None

    # ---- protocol -------------------------------------------------------

    async def setup(self) -> None:
        self.log.info(
            f"TmuxNotifier ready: session={self.session} quiet={self.quiet} "
            f"recent_chat_min={self.recent_min} bypass={sorted(self.bypass)}"
        )

    async def keepalive(self) -> None:
        return

    async def teardown(self) -> None:
        return

    async def send_heartbeat(self, task_id: str, trigger: str, prompt: str) -> None:
        line = f"[♥{task_id}:{trigger}] {prompt}"
        try:
            if trigger not in self.bypass:
                if self._in_quiet_hours():
                    self.log.info(f"skip [{task_id}:{trigger}]: quiet hours {self.quiet}")
                    self._consume_perturbation()
                    return
                ago = await asyncio.to_thread(self._minutes_since_her_last_message)
                if ago is not None and ago < self.recent_min:
                    self.log.info(f"skip [{task_id}:{trigger}]: she wrote {ago:.0f} min ago")
                    self._consume_perturbation()
                    return
            if not await self._has_session():
                self.log.warning(f"skip [{task_id}:{trigger}]: tmux session '{self.session}' not found")
                self._consume_perturbation()
                return
            await self._tmux("send-keys", "-t", self.session, "-l", line)
            await asyncio.sleep(self.enter_delay)
            await self._tmux("send-keys", "-t", self.session, "Enter")
            self.log.info(f"typed into tmux '{self.session}': {line}")
        except Exception as e:  # never let delivery problems kill the scheduler
            self.log.warning(f"TmuxNotifier error [{task_id}:{trigger}]: {e}")

    # ---- helpers --------------------------------------------------------

    def _now_local(self) -> datetime:
        if ZoneInfo is not None:
            try:
                return datetime.now(ZoneInfo(self.tz_name))
            except Exception:
                pass
        return datetime.now(timezone(timedelta(hours=8)))

    def _in_quiet_hours(self) -> bool:
        if not self.quiet:
            return False
        start, end = self.quiet
        h = self._now_local().hour
        if start <= end:
            return start <= h < end
        return h >= start or h < end

    async def _tmux(self, *args: str) -> int:
        proc = await asyncio.create_subprocess_exec(
            self.tmux, *args,
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
        )
        return await proc.wait()

    async def _has_session(self) -> bool:
        return (await self._tmux("has-session", "-t", self.session)) == 0

    def _secret(self) -> str:
        try:
            for raw in self.relay_env.read_text(encoding="utf-8").splitlines():
                if raw.startswith("RELAY_SECRET="):
                    return raw.split("=", 1)[1].strip()
        except OSError:
            pass
        return ""

    def _minutes_since_her_last_message(self) -> float | None:
        """Minutes since the last message *she* sent, or None if unknown."""
        secret = self._secret()
        if not secret:
            self.log.warning("recent-chat check: no RELAY_SECRET; not blocking")
            return None
        try:
            for _ in range(200):
                url = f"{self.relay_url}/app/history?since={self._cursor}&limit=500"
                req = urllib.request.Request(url, headers={"Authorization": f"Bearer {secret}"})
                with urllib.request.urlopen(req, timeout=10) as r:
                    msgs = json.load(r).get("messages", [])
                for m in msgs:
                    try:
                        self._cursor = max(self._cursor, int(m.get("id") or 0))
                    except (TypeError, ValueError):
                        pass
                    if m.get("from") == "human":
                        ts = _parse_ts(m.get("ts") or "")
                        if ts and (self._last_human is None or ts > self._last_human):
                            self._last_human = ts
                if len(msgs) < 500:
                    break
        except Exception as e:
            self.log.warning(f"recent-chat check failed ({e}); not blocking")
            return None
        if self._last_human is None:
            return None
        return (datetime.now(timezone.utc) - self._last_human).total_seconds() / 60.0

    def _consume_perturbation(self) -> None:
        """A skipped heartbeat shouldn't leave its hint waiting for the next wake."""
        p = Path((self.cfg.get("paths") or {}).get("perturbation", str(SCHEDULER_DIR / "perturbation.json")))
        try:
            data = json.loads(p.read_text(encoding="utf-8"))
            if not data.get("consumed"):
                data["consumed"] = True
                tmp = p.with_suffix(p.suffix + ".tmp")
                tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
                tmp.replace(p)
        except Exception:
            pass
