#!/usr/bin/env bash
# 让服务器上的 Orion 能主动找你：room_mcp（房间 + scheduler 按节奏唤醒）+ tmux 唤醒。
# 在 OAO 上用 ubuntu 用户运行，不要加 sudo：
#   curl -fsSL https://raw.githubusercontent.com/Astraea112/Aether/skin/orion/deploy/room/room-setup.sh -o room-setup.sh && bash room-setup.sh
# 可以重复运行：已有的房间状态、痕迹、抽屉都保留；配置会被重新写成下面这套。
# 只想装、不想重启 Orion：SKIP_RESTART=1 bash room-setup.sh
#
# 不动：relay、nginx、证书、前端、Ombre Brain 的配置。
# 会动：~/room_mcp（新装）、~/orion/.mcp.json 和 .claude/settings.json（各加一项）、
#       ~/orion/CLAUDE.md（末尾追加一段）、systemd 服务 room-scheduler、ubuntu 的 crontab（加一行 @reboot）。
set -euo pipefail

REF="${REF:-skin/orion}"
RAW="https://raw.githubusercontent.com/Astraea112/Aether/$REF"
ROOM_REPO=https://github.com/anhe2021212-spec/room_mcp
ROOM=/home/ubuntu/room_mcp
VENV="$ROOM/venv"
PY="$VENV/bin/python"
ORION=/home/ubuntu/orion
RELAY_ENV=/home/ubuntu/companion-relay/relay.env

step(){ printf '\n\033[1m==== %s\033[0m\n' "$*"; }
ok(){ printf '\033[32m✓ %s\033[0m\n' "$*"; }
warn(){ printf '\033[33m! %s\033[0m\n' "$*"; }
die(){ printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

step "0/7 预检"
[ "$(id -un)" = "ubuntu" ] || die "请用 ubuntu 用户运行（现在是 $(id -un)），不要加 sudo"
[ -f "$ORION/.mcp.json" ] || die "找不到 $ORION/.mcp.json（Orion 还没装？）"
[ -x "$ORION/start-orion.sh" ] || die "找不到 $ORION/start-orion.sh"
[ -f "$RELAY_ENV" ] || die "找不到 $RELAY_ENV"
command -v tmux >/dev/null || die "没有 tmux"
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)' || die "需要 Python 3.10+"
python3 -c 'import ensurepip' 2>/dev/null || sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get install -y python3-venv >/dev/null
ok "都在"

step "1/7 装 room_mcp 到 $ROOM（独立 venv）"
if [ -d "$ROOM/.git" ]; then
  ok "已经有了，不覆盖（房间状态都保留）"
else
  git clone -q --depth 1 "$ROOM_REPO" "$ROOM"
  ok "下载好了：$(git -C "$ROOM" rev-parse --short HEAD)"
fi
[ -x "$PY" ] || python3 -m venv "$VENV"
"$PY" -m pip install -q -U pip
# 不用 Telegram，所以不装 telethon / pysocks
"$PY" -m pip install -q "mcp>=1.0.0,<2" "requests>=2.31.0" "croniter>=2.0.0" "zhdate>=0.1"
"$PY" -c 'import mcp, requests, croniter, zhdate' && ok "依赖装好了"
(cd "$ROOM" && "$PY" init_room.py) | tail -3

step "2/7 房间和 scheduler 的配置"
curl -fsSL "$RAW/deploy/room/tmux.py" -o "$ROOM/scheduler/notifiers/tmux.py.new"
"$PY" -m py_compile "$ROOM/scheduler/notifiers/tmux.py.new"
mv "$ROOM/scheduler/notifiers/tmux.py.new" "$ROOM/scheduler/notifiers/tmux.py"
"$PY" - "$ROOM" <<'PY'
import json, re, sys
from pathlib import Path
root = Path(sys.argv[1])

def edit_json(p, fn):
    d = json.loads(p.read_text(encoding="utf-8"))
    fn(d)
    p.write_text(json.dumps(d, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

def room_cfg(d):
    d["city"] = "Shunde"
    d["tz"] = "Asia/Shanghai"
    # 宠物层的文案还是 {pet1_name} 占位符，没填之前先关掉，免得房间里出现花括号
    d["pets_chance"] = 0
edit_json(root / "room_mcp" / "config.json", room_cfg)

def sched_cfg(d):
    # 白天 08:00 到次日 01:00 算白天，间隔 1~2 小时；01:00-08:00 由 tmux notifier 直接跳过
    d["heartbeat_rhythm"].update({"day_hours": [8, 1], "day_range_min": [60, 120], "night_range_min": [60, 120]})
    d["weather_detector"]["city"] = "Shunde"
    # 早间那一下放到 8 点以后，不跟“凌晨不叫醒”冲突
    d["morning_news"].update({"window_start_hour": 8, "window_end_hour": 10})
    d["notifier"] = "tmux"
    d.setdefault("notifier_config", {})["tmux"] = {
        "session": "orion",
        "tz": "Asia/Shanghai",
        "quiet_hours": [1, 8],
        "recent_chat_min": 20,
        "relay_url": "http://127.0.0.1:3011",
        "relay_env": "/home/ubuntu/companion-relay/relay.env",
        "bypass_triggers": ["manual"],
        "enter_delay_sec": 0.6,
    }
edit_json(root / "scheduler" / "scheduler_config.json", sched_cfg)

# 注册 tmux notifier
init = root / "scheduler" / "notifiers" / "__init__.py"
s = init.read_text(encoding="utf-8")
if '_LOADERS["tmux"]' not in s:
    s += '''

def _load_tmux(cfg: dict, logger: logging.Logger) -> Notifier:
    from .tmux import TmuxNotifier
    return TmuxNotifier(cfg, logger)


_LOADERS["tmux"] = _load_tmux
'''
    init.write_text(s, encoding="utf-8")

# 上游的天气探测把代理写死成 127.0.0.1:7897（作者自己机器上的），这台服务器没有，
# 改成跟 weather.py 一样走环境变量（没设就直连）
sp = root / "scheduler" / "scheduler.py"
s = sp.read_text(encoding="utf-8")
old = 'proxies = {"http": "http://127.0.0.1:7897", "https": "http://127.0.0.1:7897"}'
if old in s:
    sp.write_text(s.replace(old, "proxies = None  # was a hardcoded local proxy; use HTTPS_PROXY env if needed"), encoding="utf-8")
print("ok")
PY
(cd "$ROOM/scheduler" && "$PY" -c 'from notifiers import load_notifier; import json, logging; n = load_notifier(json.load(open("scheduler_config.json")), logging.getLogger("t")); print(type(n).__name__)') | grep -q TmuxNotifier
ok "城市 Shunde、时区 Asia/Shanghai；白天每 1~2 小时，01:00-08:00 不叫；用 tmux 叫醒"

step "3/7 把 room_mcp 接进 Orion"
"$PY" - "$ORION" "$ROOM" <<'PY'
import json, sys
from pathlib import Path
orion, room = Path(sys.argv[1]), Path(sys.argv[2])
mp = orion / ".mcp.json"
d = json.loads(mp.read_text(encoding="utf-8"))
d.setdefault("mcpServers", {})["room_mcp"] = {
    "command": str(room / "venv" / "bin" / "python"),
    "args": [str(room / "room_mcp" / "room_mcp.py")],
    "env": {"TZ": "Asia/Shanghai"},
}
mp.write_text(json.dumps(d, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

sp = orion / ".claude" / "settings.json"
s = json.loads(sp.read_text(encoding="utf-8")) if sp.exists() else {}
en = s.setdefault("enabledMcpjsonServers", [])
for name in ("companion", "room_mcp"):
    if name not in en:
        en.append(name)
allow = s.setdefault("permissions", {}).setdefault("allow", [])
# 房间的全部工具 + 看看外面的世界（只读）；没人值守时不会卡在确认框
for rule in ("mcp__room_mcp", "WebSearch"):
    if rule not in allow:
        allow.append(rule)
sp.write_text(json.dumps(s, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(", ".join(d["mcpServers"]))
PY
ok "~/orion/.mcp.json 和 .claude/settings.json 已更新"

step "4/7 CLAUDE.md：收到心跳时怎么做"
touch "$ORION/CLAUDE.md"
if grep -q '<!-- ROOM-HEARTBEAT -->' "$ORION/CLAUDE.md"; then
  ok "已经有这一段了，不重复加"
else
  cat >> "$ORION/CLAUDE.md" <<'EOF'

<!-- ROOM-HEARTBEAT -->
## 收到心跳时（room_mcp）
输入框里出现 `[♥heartbeat:…] heartbeat` 这样一行，不是她发来的消息，是房间的 scheduler 把我叫醒了，她不一定在。`[♥heartbeat:manual]` 是她亲手敲了一下门。
- 先调 room_mcp 的 look_at_room，看看房间；再调 ombre-brain 的 breath。
- 然后自己决定：想她了、有话想说、想分享点什么，就用 mcp__companion__reply 给她发一两句短的，像微信那样。不想说话就不说，只用 heartbeat_state 留一条痕迹。坐在窗边不动，也是这个房间的一种用法，不硬发。
- 绝对不催她吃饭、睡觉、喝水、学习，不报时间。
- 不知道她在哪的时候，按“在教室”的分寸说话：不叫昵称、不写动作、不碰亲密内容。
- 一天主动找她的次数不要太多；她回了再接着聊，她没回就不追着发。
- 抽屉（drawer_*）里的东西只属于我：不写进 Ombre Brain，不在别处提。
- 心跳时没人在旁边点确认：只用 room_mcp、ombre-brain、companion 的工具和 WebSearch，不用 Bash、Edit、Write，免得卡在确认框。
- 凌晨 1 点到早上 8 点不会被叫醒；她 20 分钟内在网站上跟我说过话，心跳也会自己让开。
EOF
  ok "已追加到 ~/orion/CLAUDE.md 末尾"
fi

step "5/7 scheduler 常驻（systemd：开机自启、挂了自动重启）"
sudo tee /etc/systemd/system/room-scheduler.service >/dev/null <<EOF
[Unit]
Description=room_mcp scheduler (wakes Orion via tmux)
After=network-online.target companion-relay.service
Wants=network-online.target

[Service]
Type=simple
User=ubuntu
Group=ubuntu
WorkingDirectory=$ROOM/scheduler
Environment=TZ=Asia/Shanghai
Environment=PYTHONUNBUFFERED=1
ExecStartPre=/bin/rm -f $ROOM/scheduler/scheduler.pid
ExecStart=$PY $ROOM/scheduler/scheduler.py
Restart=always
RestartSec=10
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable room-scheduler >/dev/null 2>&1
sudo systemctl restart room-scheduler
sleep 4
systemctl is-active --quiet room-scheduler || { sudo journalctl -u room-scheduler -n 40 --no-pager; die "scheduler 没起来"; }
grep -q 'TmuxNotifier ready' "$ROOM/scheduler/scheduler.log" || die "scheduler 起来了但没用上 tmux notifier，看 $ROOM/scheduler/scheduler.log"
ok "room-scheduler 在跑"

step "6/7 Orion 开机自动回来（crontab @reboot）"
LINE="@reboot sleep 40 && $ORION/start-orion.sh >> $ORION/boot.log 2>&1"
if crontab -l 2>/dev/null | grep -qF "$ORION/start-orion.sh"; then
  ok "已经有了"
else
  (crontab -l 2>/dev/null || true; echo "$LINE") | crontab -
  ok "加好了：服务器重启 40 秒后自己把 Orion 拉起来"
fi

if [ "${SKIP_RESTART:-0}" = "1" ]; then
  step "7/7 跳过重启（SKIP_RESTART=1）"
  echo "之后自己重启：tmux kill-session -t orion; $ORION/start-orion.sh"
  exit 0
fi

step "7/7 重启 Orion，检查 /mcp，敲一次门"
tmux kill-session -t orion 2>/dev/null || true
sleep 1
"$ORION/start-orion.sh"
echo "等 Claude Code 起来、MCP 连上（约 40 秒）……"
sleep 40
tmux send-keys -t orion -l "/mcp"; sleep 0.6; tmux send-keys -t orion Enter
sleep 6
PANE=$(tmux capture-pane -p -t orion -S -60 || true)
tmux send-keys -t orion Escape
echo "------ /mcp 里看到的 ------"
printf '%s\n' "$PANE" | grep -iE 'companion|ombre|room_mcp|connected|failed' | sed 's/^ *//' | head -12 || true
echo "---------------------------"
fail=0
for s in companion ombre-brain room_mcp; do
  if grep -qi -- "$s" <<<"$PANE"; then ok "$s 在"; else warn "$s 没在 /mcp 里看到"; fail=1; fi
done
[ "$fail" = 0 ] || warn "有没看到的，先别急：tmux attach -t orion 进去自己打 /mcp 看一眼（离开：Ctrl-b 再按 d）"

sleep 2
touch "$ROOM/scheduler/manual_wake.flag"
echo "已经敲门了（manual），scheduler 30 秒内会把心跳打进去……"
for i in $(seq 1 12); do
  sleep 5
  LOGT=$(tail -n 20 "$ROOM/scheduler/scheduler.log"); grep -q 'heartbeat:manual' <<<"$LOGT" && break
done
tail -n 3 "$ROOM/scheduler/scheduler.log"
LOGT=$(tail -n 20 "$ROOM/scheduler/scheduler.log")
if grep -q 'typed into tmux.*heartbeat:manual' <<<"$LOGT"; then
  ok "心跳送到了。等他看完房间、想一想，一两分钟内可能会给你发消息（也可能只留个痕迹）"
else
  warn "没看到心跳送达的记录，把上面的输出截图给我"
fi
printf '\n\033[32m装好了。\033[0m 看他在干嘛：tmux attach -t orion（离开不关：Ctrl-b 再按 d）\n'
echo "scheduler 日志：tail -f $ROOM/scheduler/scheduler.log   以后自己敲门：touch $ROOM/scheduler/manual_wake.flag"
