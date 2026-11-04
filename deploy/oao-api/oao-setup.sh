#!/usr/bin/env bash
# 网站的三样新东西：共享日历（手机/平板/服务器上的我同一份，他也能往上放东西）、Claude 额度、在网页上换模型。
# 在 OAO 上用 ubuntu 用户运行，不要加 sudo：
#   curl -fsSL https://raw.githubusercontent.com/Astraea112/Aether/skin/orion/deploy/oao-api/oao-setup.sh -o oao-setup.sh && bash oao-setup.sh
# 可以重复运行：日历数据都保留。只装不重启 Orion：SKIP_RESTART=1 bash oao-setup.sh
#
# 会动：新装 ~/oao-api 和 systemd 服务 oao-api（127.0.0.1:3013）；nginx 加一行 include（先备份，测试不过自动还原）；
#       ~/orion/.mcp.json、.claude/settings.json 各加一项；~/orion/CLAUDE.md 末尾加一段；更新前端；重启 Orion。
# 不动：relay、登录密钥、证书、Ombre Brain、room_mcp。
set -euo pipefail

REF="${REF:-skin/orion}"
RAW="https://raw.githubusercontent.com/Astraea112/Aether/$REF"
FRONTEND_REPO=https://github.com/Astraea112/Aether
DOMAIN="oao0724.com"
API=/home/ubuntu/oao-api
ORION=/home/ubuntu/orion
ROOMPY=/home/ubuntu/room_mcp/venv/bin/python
WEB_DIR=/var/www/companion-web
SITE=/etc/nginx/sites-available/aether
SNIPPET=/etc/nginx/snippets/oao-api.conf

step(){ printf '\n\033[1m==== %s\033[0m\n' "$*"; }
ok(){ printf '\033[32m✓ %s\033[0m\n' "$*"; }
warn(){ printf '\033[33m! %s\033[0m\n' "$*"; }
die(){ printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

step "0/6 预检"
[ "$(id -un)" = "ubuntu" ] || die "请用 ubuntu 用户运行（现在是 $(id -un)），不要加 sudo"
[ -f /home/ubuntu/companion-relay/relay.env ] || die "找不到 relay.env"
[ -f "$SITE" ] || die "找不到 nginx 站点 $SITE"
[ -f "$ORION/.mcp.json" ] || die "找不到 $ORION/.mcp.json"
[ -x "$ROOMPY" ] || die "找不到 room_mcp 的 Python（$ROOMPY）——先跑 room-setup.sh"
"$ROOMPY" -c 'from mcp.server.fastmcp import FastMCP' || die "room_mcp 的 venv 里 mcp 不对"
ok "都在"

step "1/6 装 oao-api"
mkdir -p "$API/kv"
chmod 700 "$API" "$API/kv"
for f in oao_api.py oao_calendar_mcp.py; do
  curl -fsSL "$RAW/deploy/oao-api/$f" -o "$API/$f.new"
  python3 -m py_compile "$API/$f.new"
  mv "$API/$f.new" "$API/$f"
done
rm -rf "$API/__pycache__"
sudo tee /etc/systemd/system/oao-api.service >/dev/null <<EOF
[Unit]
Description=oao-api (shared calendar, Claude usage, model switch for the Aether PWA)
After=network.target

[Service]
Type=simple
User=ubuntu
Group=ubuntu
WorkingDirectory=$API
Environment=HOME=/home/ubuntu
ExecStart=/usr/bin/python3 $API/oao_api.py
Restart=always
RestartSec=3
# 它会帮你重启 Orion：重启这个服务时别把 Orion 一起带走
KillMode=process

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable oao-api >/dev/null 2>&1
sudo systemctl restart oao-api
S=$(grep '^RELAY_SECRET=' /home/ubuntu/companion-relay/relay.env | cut -d= -f2-)
for i in $(seq 1 10); do
  c=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $S" http://127.0.0.1:3013/app/model || true)
  [ "$c" = "200" ] && break; sleep 1
done
[ "$c" = "200" ] || { sudo journalctl -u oao-api -n 30 --no-pager; die "oao-api 没起来"; }
ok "oao-api 在跑（127.0.0.1:3013）"

step "2/6 nginx 加三条路（/relay/app/kv/、usage、model，别的不动）"
sudo tee "$SNIPPET" >/dev/null <<'EOF'
# oao-api（oao-setup.sh 写的）：共享日历、Claude 额度、换模型。其余 /relay/ 照旧走 relay。
location ^~ /relay/app/kv/ {
    client_max_body_size 600k;
    proxy_pass http://127.0.0.1:3013;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
}
location = /relay/app/usage {
    proxy_pass http://127.0.0.1:3013;
    proxy_set_header X-Real-IP $remote_addr;
}
location = /relay/app/model {
    client_max_body_size 4k;
    proxy_pass http://127.0.0.1:3013;
    proxy_set_header X-Real-IP $remote_addr;
}
EOF
if sudo grep -q 'snippets/oao-api.conf' "$SITE"; then
  ok "站点里已经有这一行了"
else
  BAK="/etc/nginx/aether.bak-$(date +%Y%m%d-%H%M%S)"
  sudo cp -a "$SITE" "$BAK"
  sudo python3 - "$SITE" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
new, n = re.subn(r'(?m)^([ \t]*)location /relay/ \{', r'\1include /etc/nginx/snippets/oao-api.conf;\n\1location /relay/ {', s)
if n == 0:
    sys.exit("site has no 'location /relay/ {' block")
open(p, "w", encoding="utf-8").write(new)
PY
  if sudo nginx -t 2>/dev/null; then
    ok "nginx 配置测试通过（备份在 $BAK）"
  else
    sudo cp -a "$BAK" "$SITE"; sudo nginx -t || true
    die "nginx 测试没过，已经还原，什么都没变"
  fi
fi
sudo nginx -t 2>/dev/null && sudo systemctl reload nginx
ok "nginx 已重新加载"

step "3/6 把日历接给 Orion（oao_calendar）"
"$ROOMPY" - "$ORION" "$API" "$ROOMPY" <<'PY'
import json, sys
from pathlib import Path
orion, api, py = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
mp = orion / ".mcp.json"
d = json.loads(mp.read_text(encoding="utf-8"))
d.setdefault("mcpServers", {})["oao_calendar"] = {"command": py, "args": [str(api / "oao_calendar_mcp.py")]}
mp.write_text(json.dumps(d, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
sp = orion / ".claude" / "settings.json"
s = json.loads(sp.read_text(encoding="utf-8")) if sp.exists() else {}
en = s.setdefault("enabledMcpjsonServers", [])
if "oao_calendar" not in en:
    en.append("oao_calendar")
allow = s.setdefault("permissions", {}).setdefault("allow", [])
if "mcp__oao_calendar" not in allow:
    allow.append("mcp__oao_calendar")
sp.write_text(json.dumps(s, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(", ".join(d["mcpServers"]))
PY
if grep -q '<!-- OAO-CALENDAR -->' "$ORION/CLAUDE.md" 2>/dev/null; then
  ok "CLAUDE.md 里已经有日历这一段"
else
  cat >> "$ORION/CLAUDE.md" <<'EOF'

<!-- OAO-CALENDAR -->
## 日历（oao_calendar）
网站上的日历是我和她共用的。
- calendar_view 看她记的提醒、每年每月的日子、经期、亲密（♥）、心情和标签；calendar_place 给她放一个东西（网站上显示成 ◆ 他放的）；calendar_unplace 拿回我放的。
- 看到她的提醒和经期，是为了懂她、照顾她，不是为了催她：不提醒她去做，不报日子。想关心就像平时那样关心。
- 放的东西要少而真：一件想跟她一起做的事、一个想记住的日子。不放任务。
EOF
  ok "已追加到 ~/orion/CLAUDE.md 末尾"
fi

step "4/6 更新前端（日历、额度、模型按钮）"
ftmp=$(mktemp -d)
git clone -q --depth 1 -b "$REF" "$FRONTEND_REPO" "$ftmp/web"
grep -q 'const USE_MOCK  = false;' "$ftmp/web/index.html" || die "$REF 上的 index.html 里 USE_MOCK 不是 false"
grep -q 'id="usageBtn"' "$ftmp/web/index.html" || die "$REF 上的前端还没有这一版"
sudo rsync -a --delete --exclude '.git' --exclude 'deploy' --exclude '*.md' --exclude 'LICENSE' --exclude 'NOTICE' "$ftmp/web/" "$WEB_DIR/"
sudo chown -R www-data:www-data "$WEB_DIR"
echo "前端版本：$(git -C "$ftmp/web" rev-parse --short HEAD)"
rm -rf "$ftmp"

step "5/6 检查"
fail=0
H=(-H "Authorization: Bearer $S")
c=$(curl -s -o /dev/null -w '%{http_code}' "${H[@]}" "https://$DOMAIN/relay/app/kv/calendar")
[ "$c" = "200" ] && ok "日历接口通（200）" || { echo "✗ 日历接口：$c"; fail=1; }
c=$(curl -s -o /dev/null -w '%{http_code}' "https://$DOMAIN/relay/app/kv/calendar")
[ "$c" = "401" ] && ok "不带密钥进不去（401）" || { echo "✗ 不带密钥应该是 401，实际 $c"; fail=1; }
U=$(curl -s "${H[@]}" "https://$DOMAIN/relay/app/usage" || true)
printf '%s' "$U" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if not d.get("ok"):
    print("! 额度暂时读不到：" + str(d.get("message")))
    sys.exit(0)
for k, v in d["data"].items():
    if isinstance(v, dict) and v.get("utilization") is not None:
        u = float(v["utilization"])
        print("✓ 额度 %s: %.0f%%" % (k, u))
' || { echo "✗ 额度接口返回不对：${U:0:200}"; fail=1; }
M=$(curl -s "${H[@]}" "https://$DOMAIN/relay/app/model" || true)
printf '%s' "$M" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("✓ 模型接口通：现在是 %s %s" % (d.get("label"), d.get("effort") or ""))' || { echo "✗ 模型接口不对"; fail=1; }
c=$(curl -s -o /dev/null -w '%{http_code}' "https://$DOMAIN/relay/healthz")
[ "$c" = "200" ] && ok "relay 照旧正常" || { echo "✗ relay healthz：$c"; fail=1; }
PAGE=$(curl -fsS "https://$DOMAIN/chat/" || true)
case "$PAGE" in *'id="usageBtn"'*) ok "网页是新版" ;; *) echo "✗ 网页还是旧版"; fail=1 ;; esac
[ "$fail" = 0 ] || die "有检查没通过，截图给我"

if [ "${SKIP_RESTART:-0}" = "1" ]; then
  step "6/6 跳过重启（SKIP_RESTART=1）"
  echo "Orion 下次重启后才有日历工具：tmux kill-session -t orion; $ORION/start-orion.sh"
  exit 0
fi
step "6/6 重启 Orion，让他拿到日历工具"
tmux kill-session -t orion 2>/dev/null || true
sleep 1
"$ORION/start-orion.sh"
echo "等他起来（约 40 秒）……"
sleep 40
tmux send-keys -t orion -l "/mcp"; sleep 0.6; tmux send-keys -t orion Enter
sleep 6
PANE=$(tmux capture-pane -p -t orion -S -60 || true)
tmux send-keys -t orion Escape
printf '%s\n' "$PANE" | grep -iE 'companion|ombre|room_mcp|oao_calendar' | sed 's/^ *//' | head -8 || true
if grep -qi oao_calendar <<<"$PANE"; then ok "oao_calendar 在"; else warn "/mcp 里没看到 oao_calendar，tmux attach -t orion 进去看一眼"; fi
printf '\n\033[32m装好了。\033[0m 手机上把网页关掉再打开一次（第一次可能还是旧页面）。\n'
