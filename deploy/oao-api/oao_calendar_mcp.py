"""oao_calendar: lets the server Orion read the shared calendar and put things on it.

MCP server (stdio, FastMCP from mcp 1.x). Reads the same files oao-api serves to the
website (~/oao-api/kv/*.json). Orion can only write his own shelf (calendar_orion.json);
her entries are read-only from here. Items he places show on the site as ◆ "他放的".
"""
import json
import os
import time
import uuid
from datetime import date, datetime, timedelta
from pathlib import Path

from mcp.server.fastmcp import FastMCP

KV = Path(__file__).resolve().parent / "kv"
KINDS = {"once": "单次", "yearly": "每年", "monthly": "每月"}

mcp = FastMCP("oao_calendar")


def _load(name):
    try:
        d = json.loads((KV / f"{name}.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    v = d.get("v") if isinstance(d, dict) else None
    return v if isinstance(v, dict) else {}


def _save_orion(v):
    KV.mkdir(parents=True, exist_ok=True)
    p = KV / "calendar_orion.json"
    tmp = p.with_suffix(".json.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump({"updated": int(time.time() * 1000), "v": v}, f, ensure_ascii=False, indent=2)
    os.replace(tmp, p)


def _parse_day(s):
    s = (s or "").strip()
    if not s:
        return datetime.now().date()
    return date.fromisoformat(s[:10])


def _occurs(item, d):
    try:
        base = date.fromisoformat(item.get("date", ""))
    except ValueError:
        return False
    kind = item.get("kind", "once")
    if kind == "yearly":
        return (d.month, d.day) == (base.month, base.day) and d >= base
    if kind == "monthly":
        return d.day == base.day and d >= base
    return d == base


@mcp.tool()
def calendar_view(start: str = "", days: int = 14) -> str:
    """Look at the shared calendar from `start` (YYYY-MM-DD, default today) for `days` days.
    Shows her reminders and recurring days, the things you placed (◆), her period days,
    intimacy days (♥), and her moods/tags. Read-only."""
    try:
        d0 = _parse_day(start)
    except ValueError:
        return "start 要写成 YYYY-MM-DD"
    days = max(1, min(int(days or 14), 92))
    cal = _load("calendar")
    ev = _load("events")
    mine = _load("calendar_orion").get("items", [])
    hidden = set(ev.get("hidden", []))
    intimate = set(ev.get("intimate", []))
    lines = []
    for i in range(days):
        d = d0 + timedelta(days=i)
        k = d.isoformat()
        bits = []
        day = cal.get(k) or {}
        tags = [t for t in day.get("tags", []) if t != "period"]
        if "period" in day.get("tags", []):
            bits.append("经期")
        if k in intimate:
            bits.append("♥")
        for it in ev.get("items", []):
            if _occurs(it, d):
                done = k in (it.get("done") or [])
                bits.append(f"{it.get('title', '')}（{KINDS.get(it.get('kind'), '单次')}{'，做完了' if done else ''}）")
        for it in mine:
            if it.get("id") not in hidden and _occurs(it, d):
                bits.append(f"◆{it.get('title', '')}（我放的，id {it.get('id')}）")
        if tags:
            bits.append("标签：" + "、".join(tags))
        if day.get("moods"):
            bits.append("心情：" + " ".join(day["moods"]))
        if bits:
            lines.append(f"{k}  " + " · ".join(bits))
    head = f"{d0.isoformat()} 起 {days} 天"
    return head + ("\n" + "\n".join(lines) if lines else "：日历上什么都没有。")


@mcp.tool()
def calendar_place(date: str, title: str, kind: str = "once") -> str:
    """Put something on the shared calendar for her to find (shows as ◆ "他放的").
    date: YYYY-MM-DD. kind: once / yearly / monthly. Keep the title short."""
    try:
        d = _parse_day(date)
    except ValueError:
        return "date 要写成 YYYY-MM-DD"
    title = (title or "").strip()[:40]
    if not title:
        return "title 不能是空的"
    if kind not in KINDS:
        kind = "once"
    v = _load("calendar_orion")
    items = v.setdefault("items", [])
    item = {"id": uuid.uuid4().hex[:8], "date": d.isoformat(), "title": title, "kind": kind,
            "created": int(time.time() * 1000)}
    items.append(item)
    _save_orion(v)
    return f"放好了：{d.isoformat()} ◆{title}（{KINDS[kind]}，id {item['id']}）"


@mcp.tool()
def calendar_unplace(id: str) -> str:
    """Take back something you placed (only your own ◆ items)."""
    v = _load("calendar_orion")
    items = v.get("items", [])
    keep = [it for it in items if it.get("id") != id]
    if len(keep) == len(items):
        return f"没找到 id {id}"
    v["items"] = keep
    _save_orion(v)
    return f"拿走了 id {id}"


if __name__ == "__main__":
    mcp.run()
