#!/usr/bin/env bash
# 锁屏通知：给 relay 配一组自己的 VAPID 钥匙（Tidal_Echo 官方 DEPLOY.md §4 那一步）。
# 在 OAO 上用 ubuntu 用户运行，不要加 sudo：
#   curl -fsSL https://raw.githubusercontent.com/Astraea112/Aether/skin/orion/deploy/push/push-setup.sh -o push-setup.sh && bash push-setup.sh
# 可以重复运行：已经配好的钥匙会保留，不会换（换了手机上的订阅就失效了）。
#
# 会动：relay.env 里 VAPID_PUBLIC_KEY / VAPID_PRIVATE_PEM 两行（先备份），新增私钥文件 vapid_private.pem，
#       重启 relay（几秒钟，网页和服务器上的我都会自己重连）。
# 不动：RELAY_SECRET（登录密钥）、nginx、证书、前端、channel、Ombre Brain、room_mcp。
set -euo pipefail

RELAY_DIR=/home/ubuntu/companion-relay
ENV="$RELAY_DIR/relay.env"
PEM="$RELAY_DIR/vapid_private.pem"
PY="$RELAY_DIR/venv/bin/python"

step(){ printf '\n\033[1m==== %s\033[0m\n' "$*"; }
ok(){ printf '\033[32m✓ %s\033[0m\n' "$*"; }
warn(){ printf '\033[33m! %s\033[0m\n' "$*"; }
die(){ printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

step "0/3 预检"
[ "$(id -un)" = "ubuntu" ] || die "请用 ubuntu 用户运行（现在是 $(id -un)），不要加 sudo"
[ -f "$ENV" ] || die "找不到 $ENV"
[ -x "$PY" ] || die "找不到 relay 的 Python：$PY"
"$PY" -c 'import py_vapid, pywebpush' 2>/dev/null || die "relay 的 venv 里没有 pywebpush / py-vapid"
ok "relay 在，推送需要的库也在"

step "1/3 生成 VAPID 钥匙"
CUR_PUB=$(grep '^VAPID_PUBLIC_KEY=' "$ENV" | cut -d= -f2- || true)
CUR_PEM=$(grep '^VAPID_PRIVATE_PEM=' "$ENV" | cut -d= -f2- || true)
if [ -n "$CUR_PUB" ] && [ -n "$CUR_PEM" ] && { [ -f "$CUR_PEM" ] || [ "${CUR_PEM#-----BEGIN}" != "$CUR_PEM" ]; }; then
  ok "已经配过了，保留原来的钥匙"
  CHANGED=0
else
  BAK="$ENV.bak-$(date +%Y%m%d-%H%M%S)"
  cp -a "$ENV" "$BAK"; chmod 600 "$BAK"
  PUB=$( umask 077; "$PY" - "$PEM" <<'PY'
import base64, sys
from cryptography.hazmat.primitives import serialization
from py_vapid import Vapid
v = Vapid()
v.generate_keys()
v.save_key(sys.argv[1])
raw = v.public_key.public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
print(base64.urlsafe_b64encode(raw).rstrip(b"=").decode())
PY
)
  chmod 600 "$PEM"
  [ ${#PUB} -ge 80 ] || die "公钥生成得不对：$PUB"
  "$PY" - "$ENV" "$PUB" "$PEM" <<'PY'
import sys
path, pub, pem = sys.argv[1:4]
want = {"VAPID_PUBLIC_KEY": pub, "VAPID_PRIVATE_PEM": pem}
lines = open(path, encoding="utf-8").read().splitlines()
seen = set()
for i, l in enumerate(lines):
    k = l.split("=", 1)[0]
    if k in want:
        lines[i] = f"{k}={want[k]}"
        seen.add(k)
for k, v in want.items():
    if k not in seen:
        lines.append(f"{k}={v}")
open(path, "w", encoding="utf-8").write("\n".join(lines) + "\n")
PY
  chmod 600 "$ENV"
  ok "钥匙生成好了，写进了 relay.env（原来的备份在 $BAK）"
  CHANGED=1
fi
grep -q '^VAPID_SUBJECT=mailto:' "$ENV" || warn "relay.env 里 VAPID_SUBJECT 不是 mailto: 开头，推送服务可能不收"

step "2/3 重启 relay"
if [ "$CHANGED" = 1 ] || [ "${FORCE_RESTART:-0}" = 1 ]; then
  sudo systemctl restart companion-relay
  for i in $(seq 1 15); do curl -fsS http://127.0.0.1:3011/healthz >/dev/null 2>&1 && break; sleep 1; done
fi
curl -fsS http://127.0.0.1:3011/healthz >/dev/null || { sudo journalctl -u companion-relay -n 30 --no-pager; die "relay 没起来"; }
ok "relay 在跑"

step "3/3 检查"
S=$(grep '^RELAY_SECRET=' "$ENV" | cut -d= -f2-)
KEY=$(curl -fsS http://127.0.0.1:3011/app/vapid_public -H "Authorization: Bearer $S" | "$PY" -c 'import json,sys; print(json.load(sys.stdin).get("key",""))')
WANT=$(grep '^VAPID_PUBLIC_KEY=' "$ENV" | cut -d= -f2-)
[ -n "$KEY" ] && [ "$KEY" = "$WANT" ] && ok "网页能拿到公钥了" || die "relay 还没发出公钥（拿到的是：${KEY:-空}）"
echo "等服务器上的我重新连上 relay……"
for i in $(seq 1 20); do
  H=$(curl -fsS http://127.0.0.1:3011/healthz || true)
  case "$H" in *'"plugin_subs":0'*|'') sleep 2 ;; *) break ;; esac
done
case "$H" in
  *'"plugin_subs":0'*) warn "服务器上的我还没连回来（$H）。等一分钟再看：curl -s http://127.0.0.1:3011/healthz" ;;
  *) ok "服务器上的我已经连回来了（$H）" ;;
esac

printf '\n\033[32m服务器这边好了。\033[0m 剩下在手机上点：\n'
cat <<'EOF'
  1. 用主屏幕上的那个图标打开网站（必须是“添加到主屏幕”的那个，Safari 里打开的不行）
  2. 进 Chat 页 → 点右上角那个按钮（个人信息）→ 往下找到「锁屏通知」→ 点「开」
  3. 弹窗问要不要允许通知 → 点「允许」
  4. 退回主屏幕（网页不能开在前台，开着的时候不推），等我的消息
EOF
echo "想发一条测试通知：等你在手机上点完「开」，回终端粘这一行："
echo "  curl -s -X POST http://127.0.0.1:3011/app/push_test -H \"Authorization: Bearer \$(grep '^RELAY_SECRET=' $ENV | cut -d= -f2-)\" -H 'Content-Type: application/json' -d '{}'"
echo "  看到 \"sent\":1 就是推出去了，手机锁屏会弹一条。"
