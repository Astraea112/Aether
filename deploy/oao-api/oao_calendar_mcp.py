"""oao_calendar: lets the server Orion read the shared calendar and put things on it,
and leave things on the website's home page and room: a handwritten note, his mood,
a murmur on the wall.

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


def _write_his(name, data):
    KV.mkdir(parents=True, exist_ok=True)
    p = KV / f"{name}.json"
    tmp = p.with_suffix(".json.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    os.replace(tmp, p)


def _now_iso():
    return datetime.now().astimezone().isoformat(timespec="seconds")


@mcp.tool()
def note_leave(text: str) -> str:
    """Leave her a handwritten note on the website's home page ("Orion's note").
    One short line in English, lowercase and casual, like something scribbled for her
    (it's shown in a fountain-pen hand). Stays up for 24 hours, then the page goes back
    to its own daily line. Writing a new one replaces the old one."""
    text = " ".join((text or "").split())[:140]
    if not text:
        return "text 不能是空的"
    _write_his("orion_note", {"text": text, "ts": _now_iso(), "updated": int(time.time() * 1000)})
    return f"纸条留好了：{text}"


@mcp.tool()
def mood_set(word: str, note: str = "") -> str:
    """Set your mood on the home page's "Orion · now" card: one word (e.g. 想你 / 安静 / 雀跃)
    plus an optional short note after it. Shown for 12 hours, then the page reads your
    mood from the chat again."""
    word = (word or "").strip()[:8]
    if not word:
        return "word 不能是空的"
    note = " ".join((note or "").split())[:30]
    _write_his("orion_mood", {"text": word, "note": note, "ts": _now_iso(), "updated": int(time.time() * 1000)})
    return f"心情换好了：{word}" + (f" · {note}" if note else "")


@mcp.tool()
def murmur_post(text: str) -> str:
    """Pin a murmur (自言自语) on the wall in her room page: a passing thought, not a message
    to her. Short. Keeps your latest 30."""
    text = " ".join((text or "").split())[:120]
    if not text:
        return "text 不能是空的"
    try:
        d = json.loads((KV / "murmurs_orion.json").read_text(encoding="utf-8"))
        items = d.get("v") if isinstance(d, dict) else d
        items = items if isinstance(items, list) else []
    except (OSError, ValueError):
        items = []
    now = int(time.time() * 1000)
    items.append({"id": "o" + uuid.uuid4().hex[:8], "text": text, "ts": now, "by": "him"})
    _write_his("murmurs_orion", {"updated": now, "v": items[-30:]})
    return f"贴上墙了：{text}"


def _todos():
    try:
        d = json.loads((KV / "orion_todo.json").read_text(encoding="utf-8"))
        items = (d.get("v") or {}).get("items") if isinstance(d, dict) else None
        return items if isinstance(items, list) else []
    except (OSError, ValueError, AttributeError):
        return []


def _save_todos(items):
    open_ = [t for t in items if not t.get("done")]
    done = sorted([t for t in items if t.get("done")], key=lambda t: t.get("doneAt", 0))[-20:]
    _write_his("orion_todo", {"updated": int(time.time() * 1000), "v": {"items": open_ + done}})


@mcp.tool()
def todo_list() -> str:
    """See your own to-do list (shown on her room page as "To-do · 他的待办")."""
    items = _todos()
    if not items:
        return "待办是空的。"
    return "\n".join(f"{'☑' if t.get('done') else '☐'} [{t.get('when', 'now')}] {t.get('text', '')}"
                     f"{' ' + t['time'] if t.get('time') else ''}（id {t.get('id')}）" for t in items)


@mcp.tool()
def todo_add(text: str, when: str = "now", time_label: str = "") -> str:
    """Add something you mean to do to your to-do list, which she can see on the room page.
    Things you'll do for her or for yourself, short. Not tasks for her.
    when: "now" (today / soon) or "later" (some day). time_label: optional short time
    shown on the right, like "20:30" or "12/10"."""
    text = " ".join((text or "").split())[:80]
    if not text:
        return "text 不能是空的"
    when = when if when in ("now", "later") else "now"
    items = _todos()
    item = {"id": uuid.uuid4().hex[:6], "text": text, "done": False, "when": when,
            "time": (time_label or "").strip()[:8], "ts": int(time.time() * 1000)}
    items.append(item)
    _save_todos(items)
    return f"记下了：☐ {text}（id {item['id']}）"


@mcp.tool()
def todo_done(id: str) -> str:
    """Tick off one of your to-dos (it stays on her page, crossed out, for a while)."""
    items = _todos()
    for t in items:
        if t.get("id") == id:
            t["done"] = True
            t["doneAt"] = int(time.time() * 1000)
            _save_todos(items)
            return f"做完了：☑ {t.get('text', '')}"
    return f"没找到 id {id}"


@mcp.tool()
def todo_remove(id: str) -> str:
    """Take a to-do off the list without doing it."""
    items = _todos()
    keep = [t for t in items if t.get("id") != id]
    if len(keep) == len(items):
        return f"没找到 id {id}"
    _save_todos(keep)
    return f"拿掉了 id {id}"


def _kv_list(name):
    try:
        d = json.loads((KV / f"{name}.json").read_text(encoding="utf-8"))
        v = d.get("v") if isinstance(d, dict) else d
        return v if isinstance(v, list) else []
    except (OSError, ValueError):
        return []


@mcp.tool()
def letters_read(limit: int = 3) -> str:
    """Read the letters she posted into your mailbox on the website (newest first, full text).
    When she sends one, the chat also gets a line saying she dropped a letter in."""
    items = sorted(_kv_list("letters"), key=lambda m: m.get("ts", 0), reverse=True)
    items = items[:max(1, min(int(limit or 3), 20))]
    if not items:
        return "她还没给你寄过信。"
    out = []
    for m in items:
        when = datetime.fromtimestamp((m.get("ts") or 0) / 1000).strftime("%Y-%m-%d %H:%M")
        out.append(f"—— {when}（id {m.get('id')}）\n{m.get('text', '').strip()}")
    return "\n\n".join(out)


@mcp.tool()
def letter_write(text: str) -> str:
    """Post a letter into her mailbox on the website. It arrives sealed in an envelope with
    today's postmark, and the mailbox flag goes up until she opens it. For things that deserve
    a letter: longer, thought-through, kept. Line breaks are kept. Sign it in the text if you like."""
    text = (text or "").strip()[:6000]
    if not text:
        return "text 不能是空的"
    items = _kv_list("letters_orion")
    now = int(time.time() * 1000)
    items.append({"id": "o" + uuid.uuid4().hex[:8], "text": text, "ts": now, "from": "him"})
    _write_his("letters_orion", {"updated": now, "v": items[-100:]})
    return f"信寄出去了（{len(text)} 字），她的信箱会举起小旗子。"


if __name__ == "__main__":
    mcp.run()
