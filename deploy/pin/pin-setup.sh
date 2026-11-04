#!/usr/bin/env bash
# 网页登录改成 6 位数字密码（原来那串完整密钥照旧能用，留作备用）。
# 在 OAO 上用 ubuntu 用户运行，不要加 sudo，也不要用 curl | bash（要在终端里输密码）：
#   curl -fsSL https://raw.githubusercontent.com/Astraea112/Aether/skin/orion/deploy/pin/pin-setup.sh -o pin-setup.sh && bash pin-setup.sh
# 可以重复运行：已经设过的数字密码会保留。想换一个：RESET_PIN=1 bash pin-setup.sh
#
# 做了什么：
#   1. 装一个小程序 pin-gate（127.0.0.1:3012，ubuntu 用户跑），只负责“6 位数字 → 完整密钥”；
#      relay 本身、relay.env 里的密钥、channel 配置一律不动。
#   2. 数字密码只存加盐哈希（pin.env），不存原文。错 5 次锁 15 分钟，一天最多错 20 次。
#   3. nginx 只加一行 include（先备份，测试不过自动还原），证书不动。
#   4. 把前端更新到带数字键盘的版本。
set -euo pipefail

REF="${REF:-skin/orion}"
RAW="https://raw.githubusercontent.com/Astraea112/Aether/$REF"
FRONTEND_REPO=https://github.com/Astraea112/Aether
DOMAIN="oao0724.com"
RELAY_DIR=/home/ubuntu/companion-relay
WEB_DIR=/var/www/companion-web
SITE=/etc/nginx/sites-available/aether
SNIPPET=/etc/nginx/snippets/oao-pin.conf

step(){ printf '\n\033[1m==== %s\033[0m\n' "$*"; }
ok(){ printf '\033[32m✓ %s\033[0m\n' "$*"; }
die(){ printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

step "0/5 预检"
[ "$(id -un)" = "ubuntu" ] || die "请用 ubuntu 用户运行（现在是 $(id -un)），不要加 sudo"
[ -t 0 ] || die "要在终端里输密码：请先下载再运行（bash pin-setup.sh），不要用 curl | bash"
[ -f "$RELAY_DIR/relay.env" ] || die "找不到 $RELAY_DIR/relay.env"
grep -q '^RELAY_SECRET=' "$RELAY_DIR/relay.env" || die "relay.env 里没有 RELAY_SECRET"
[ -f "$SITE" ] || die "找不到 nginx 站点 $SITE"
ok "relay 和 nginx 都在"

step "1/5 装 pin-gate"
curl -fsSL "$RAW/deploy/pin/pin-gate.py" -o "$RELAY_DIR/pin-gate.py.new"
python3 -m py_compile "$RELAY_DIR/pin-gate.py.new"
mv "$RELAY_DIR/pin-gate.py.new" "$RELAY_DIR/pin-gate.py"
rm -rf "$RELAY_DIR/__pycache__"
chmod 700 "$RELAY_DIR/pin-gate.py"
ok "程序放在 $RELAY_DIR/pin-gate.py"

step "2/5 设数字密码"
NEWPIN=""
if [ -f "$RELAY_DIR/pin.env" ] && [ "${RESET_PIN:-0}" != "1" ]; then
  ok "已经设过数字密码，保留原来的（想换：RESET_PIN=1 bash pin-setup.sh）"
else
  while :; do
    read -rsp "请输入 6 位数字密码（输的时候屏幕上不显示，正常）： " p1; echo
    if ! [[ "$p1" =~ ^[0-9]{6}$ ]]; then echo "  要正好 6 位数字，再来一次"; continue; fi
    if [[ "$p1" =~ ^(.)\1{5}$ ]] || [ "$p1" = "123456" ] || [ "$p1" = "654321" ]; then
      echo "  这个太好猜了，换一个"; continue
    fi
    read -rsp "再输一次确认： " p2; echo
    [ "$p1" = "$p2" ] && break
    echo "  两次不一样，重新来"
  done
  ( umask 077
    printf '%s' "$p1" | python3 -c '
import hashlib, os, sys
pin = sys.stdin.read()
salt = os.urandom(16)
h = hashlib.pbkdf2_hmac("sha256", pin.encode(), salt, 200000)
print("PIN_SALT=" + salt.hex()); print("PIN_HASH=" + h.hex()); print("PIN_ITER=200000")
' > "$RELAY_DIR/pin.env" )
  chmod 600 "$RELAY_DIR/pin.env"
  rm -f "$RELAY_DIR/pin-state.json"
  NEWPIN="$p1"; unset p1 p2
  ok "数字密码已保存（只存了加密后的样子）"
fi

step "3/5 让 pin-gate 常驻"
sudo tee /etc/systemd/system/pin-gate.service >/dev/null <<EOF
[Unit]
Description=pin-gate (6-digit PIN -> relay login key)
After=network.target

[Service]
Type=simple
User=ubuntu
Group=ubuntu
WorkingDirectory=$RELAY_DIR
ExecStart=/usr/bin/python3 $RELAY_DIR/pin-gate.py
Restart=always
RestartSec=3
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable pin-gate >/dev/null 2>&1
sudo systemctl restart pin-gate
for i in $(seq 1 10); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{}' http://127.0.0.1:3012/ || true)
  [ "$code" = "400" ] && break; sleep 1
done
[ "$code" = "400" ] || { sudo journalctl -u pin-gate -n 30 --no-pager; die "pin-gate 没起来"; }
ok "pin-gate 在跑（127.0.0.1:3012）"

step "4/5 nginx 加一条路（只加 /relay/pin，别的不动）"
sudo tee "$SNIPPET" >/dev/null <<'EOF'
# 6 位数字密码登录 → pin-gate（pin-setup.sh 写的）。其余 /relay/ 照旧走 relay。
location = /relay/pin {
    limit_except POST { deny all; }
    client_max_body_size 1k;
    proxy_pass http://127.0.0.1:3012;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
}
EOF
if sudo grep -q 'snippets/oao-pin.conf' "$SITE"; then
  ok "站点里已经有这一行了"
else
  BAK="/etc/nginx/aether.bak-$(date +%Y%m%d-%H%M%S)"
  sudo cp -a "$SITE" "$BAK"
  sudo python3 - "$SITE" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
new, n = re.subn(r'(?m)^([ \t]*)location /relay/ \{', r'\1include /etc/nginx/snippets/oao-pin.conf;\n\1location /relay/ {', s)
if n == 0:
    sys.exit("site has no 'location /relay/ {' block")
open(p, "w", encoding="utf-8").write(new)
PY
  if sudo nginx -t 2>/dev/null; then
    ok "nginx 配置测试通过（备份在 $BAK）"
  else
    sudo cp -a "$BAK" "$SITE"
    sudo nginx -t || true
    die "nginx 测试没过，已经还原成原来的配置，什么都没变"
  fi
fi
sudo nginx -t 2>/dev/null && sudo systemctl reload nginx
ok "nginx 已重新加载"

step "5/5 更新前端（带数字键盘的版本）"
ftmp=$(mktemp -d)
git clone -q --depth 1 -b "$REF" "$FRONTEND_REPO" "$ftmp/web"
grep -q 'const USE_MOCK  = false;' "$ftmp/web/index.html" || die "$REF 上的 index.html 里 USE_MOCK 不是 false"
grep -q 'id="pinPad"' "$ftmp/web/index.html" || die "$REF 上的前端还没有数字键盘"
sudo rsync -a --delete --exclude '.git' --exclude 'deploy' --exclude '*.md' --exclude 'LICENSE' --exclude 'NOTICE' "$ftmp/web/" "$WEB_DIR/"
sudo chown -R www-data:www-data "$WEB_DIR"
echo "前端版本：$(git -C "$ftmp/web" rev-parse --short HEAD)"
rm -rf "$ftmp"

step "检查"
fail=0
c=$(curl -s -o /dev/null -w '%{http_code}' "https://$DOMAIN/relay/pin")
[ "$c" = "403" ] && ok "GET /relay/pin 被挡住（403）" || { echo "✗ GET /relay/pin 应该是 403，实际 $c"; fail=1; }
c=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{}' "https://$DOMAIN/relay/pin")
[ "$c" = "400" ] && ok "POST /relay/pin 通到 pin-gate（400）" || { echo "✗ POST /relay/pin 应该是 400，实际 $c"; fail=1; }
c=$(curl -s -o /dev/null -w '%{http_code}' "https://$DOMAIN/relay/healthz")
[ "$c" = "200" ] && ok "relay 照旧正常（healthz 200）" || { echo "✗ relay healthz 实际 $c"; fail=1; }
if [ -n "$NEWPIN" ]; then
  res=$(printf '{"pin":"%s"}' "$NEWPIN" | curl -s -X POST -H 'Content-Type: application/json' --data-binary @- "https://$DOMAIN/relay/pin")
  want=$(grep '^RELAY_SECRET=' "$RELAY_DIR/relay.env" | cut -d= -f2-)
  got=$(printf '%s' "$res" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token",""))' 2>/dev/null || true)
  [ -n "$got" ] && [ "$got" = "$want" ] && ok "用你刚设的数字密码换到了正确的密钥" || { echo "✗ 数字密码没换到密钥"; fail=1; }
  unset NEWPIN want got res
fi
# 先整页存进变量再找：直接 curl | grep -q 会因为 grep 提前退出让 curl 报 (23)，在 pipefail 下误判成失败
page=$(curl -fsS "https://$DOMAIN/chat/" || true)
case "$page" in *'id="pinPad"'*) ok "网页已经是带数字键盘的版本" ;; *) echo "✗ 网页还是旧版"; fail=1 ;; esac

[ "$fail" = 0 ] || die "有检查没通过，把上面的输出截图给我"
printf '\n\033[32m全部完成。\033[0m 手机上把网页关掉再打开一次（第一次可能还是旧页面），退出登录后就是数字键盘。\n'
echo "完整密钥照旧能用：键盘左下角点「密钥」。"
