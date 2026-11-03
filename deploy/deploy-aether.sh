#!/usr/bin/env bash
# Aether on Tidal_Echo relay — VPS setup, everything up to (not including) Claude Code + channel.
# Conventions: Tidal_Echo official docs, defaults everywhere, except
#   - the relay runs as the `ubuntu` user (not root), from /home/ubuntu/companion-relay
#   - the certificate covers oao0724.com and www.oao0724.com
# Run on the VPS as the `ubuntu` user (needs sudo for apt / nginx / systemd / certbot):
#     curl -fsSL https://raw.githubusercontent.com/Astraea112/Aether/skin/orion/deploy/deploy-aether.sh -o deploy-aether.sh
#     bash deploy-aether.sh
# The PWA shell is pulled from FRONTEND_REPO @ FRONTEND_REF (override: FRONTEND_REF=main bash deploy-aether.sh).
# Safe to re-run: keeps an existing relay.env (and its secret), re-copies code, re-tests.
set -euo pipefail

DOMAIN="oao0724.com"
WWW="www.oao0724.com"
AI_NAME="Orion"
HUMAN_NAME="Astraea"
RELAY_USER=ubuntu
RELAY_DIR=/home/ubuntu/companion-relay
WEB_DIR=/var/www/companion-web
BACKEND_REPO=https://github.com/anhe2021212-spec/Tidal_Echo
FRONTEND_REPO=https://github.com/Astraea112/Aether
FRONTEND_REF="${FRONTEND_REF:-skin/orion}"

step(){ printf '\n\033[1m==== %s\033[0m\n' "$*"; }
die(){ printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

step "0/5 预检"
MYIP=$(curl -fsS --max-time 10 https://api.ipify.org || true)
[ "$(id -un)" = "$RELAY_USER" ] || die "请用 $RELAY_USER 用户运行（现在是 $(id -un)）"
echo "这台机器的公网 IP：${MYIP:-未知}"
for h in "$DOMAIN" "$WWW"; do
  ip=$(getent ahostsv4 "$h" | awk 'NR==1{print $1}' || true)
  echo "  $h 解析到：${ip:-（没解析）}"
  [ -n "$ip" ] && [ "$ip" = "$MYIP" ] || die "$h 还没指向这台机器，签证书会失败；等解析生效再跑"
done

step "1/5 装环境"
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  python3 python3-venv python3-pip nginx certbot python3-certbot-nginx git rsync curl
python3 --version

step "2/5 relay 后端"
tmp=$(mktemp -d)
git clone --depth 1 "$BACKEND_REPO" "$tmp/te"
mkdir -p "$RELAY_DIR/uploads"
cp "$tmp/te/backend/app.py" "$tmp/te/backend/requirements.txt" "$RELAY_DIR/"
[ -x "$RELAY_DIR/venv/bin/python" ] || python3 -m venv "$RELAY_DIR/venv"
"$RELAY_DIR/venv/bin/pip" install -q -U pip
"$RELAY_DIR/venv/bin/pip" install -q -r "$RELAY_DIR/requirements.txt"
if [ -f "$RELAY_DIR/relay.env" ]; then
  echo "relay.env 已存在：保留原来的密钥，不覆盖"
else
  SECRET=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
  # 不照抄 .env.example：它把注释写在值后面，systemd 不会去掉行尾注释
  umask 077
  cat > "$RELAY_DIR/relay.env" <<EOF
RELAY_SECRET=$SECRET
RELAY_AI_NAME=$AI_NAME
RELAY_HUMAN_NAME=$HUMAN_NAME
RELAY_PORT=3011
RELAY_DB=$RELAY_DIR/relay.db
RELAY_UPLOAD_DIR=$RELAY_DIR/uploads
RELAY_PUBLIC_PREFIX=/relay
RELAY_APP_PATH=/chat/
RELAY_ALLOW_ORIGINS=https://$DOMAIN
RELAY_BRAIN_FILE=$RELAY_DIR/brain_target
RELAY_LOOP_INGEST_URL=http://127.0.0.1:3020/loop/ingest
RELAY_MAX_UPLOAD_BYTES=10485760
RELAY_VOICE_MAX_BYTES=8388608
RELAY_VOICE_TRANSCRIBE_CMD=
MINIMAX_API_KEY=
MINIMAX_GROUP_ID=
MINIMAX_VOICE_ZH=
VAPID_PUBLIC_KEY=
VAPID_PRIVATE_PEM=
VAPID_SUBJECT=mailto:admin@$DOMAIN
EOF
  chmod 600 "$RELAY_DIR/relay.env"
  umask 022
  echo "已生成新的 RELAY_SECRET（只存在 $RELAY_DIR/relay.env）"
fi
# 官方 unit 是按 root + /root/companion-relay 写的;这里同内容,只换成 ubuntu 用户和对应路径
sudo tee /etc/systemd/system/companion-relay.service >/dev/null <<EOF
[Unit]
Description=companion relay backend (channel <-> PWA)
After=network.target

[Service]
Type=simple
User=$RELAY_USER
Group=$RELAY_USER
WorkingDirectory=$RELAY_DIR
EnvironmentFile=$RELAY_DIR/relay.env
ExecStart=$RELAY_DIR/venv/bin/python -m uvicorn app:app --host 127.0.0.1 --port 3011 --timeout-graceful-shutdown 3
Restart=always
TimeoutStopSec=10
RestartSec=3
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable companion-relay
sudo systemctl restart companion-relay
for i in $(seq 1 15); do curl -fsS http://127.0.0.1:3011/healthz >/dev/null 2>&1 && break; sleep 1; done
curl -fsS http://127.0.0.1:3011/healthz && echo || { sudo journalctl -u companion-relay -n 40 --no-pager; die "relay 没起来"; }
rm -rf "$tmp"

step "3/5 前端壳"
ftmp=$(mktemp -d)
git clone --depth 1 -b "$FRONTEND_REF" "$FRONTEND_REPO" "$ftmp/web"
grep -q 'const USE_MOCK  = false;' "$ftmp/web/index.html" || die "$FRONTEND_REF 上的 index.html 里 USE_MOCK 不是 false，这一版连不上 relay"
sudo mkdir -p "$WEB_DIR"
sudo rsync -a --delete --exclude '.git' --exclude 'deploy' --exclude '*.md' --exclude 'LICENSE' --exclude 'NOTICE' "$ftmp/web/" "$WEB_DIR/"
sudo chown -R www-data:www-data "$WEB_DIR"
echo "前端来自 $FRONTEND_REPO @ $FRONTEND_REF ($(git -C "$ftmp/web" rev-parse --short HEAD))"
ls "$WEB_DIR" | tr '\n' ' '; echo
rm -rf "$ftmp"

step "4/5 nginx + HTTPS"
sudo tee /etc/nginx/sites-available/aether >/dev/null <<'NGINX'
server {
    listen 80;
    listen [::]:80;
    server_name __DOMAIN__ __WWW__;

    location = / { return 302 /chat/; }

    # API — reverse proxy to the relay. SSE-friendly: no buffering, long timeouts.
    location /relay/ {
        client_max_body_size 10m;
        proxy_pass http://127.0.0.1:3011/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection '';
        proxy_buffering off;
        proxy_cache off;
        chunked_transfer_encoding off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    # PWA static files
    location = /chat { return 301 /chat/; }
    location /chat/ {
        alias /var/www/companion-web/;
        index index.html;
    }
    location = /chat/manifest.webmanifest {
        alias /var/www/companion-web/manifest.webmanifest;
        default_type application/manifest+json;
    }
}
NGINX
sudo sed -i "s/__DOMAIN__/$DOMAIN/; s/__WWW__/$WWW/" /etc/nginx/sites-available/aether
sudo ln -sf /etc/nginx/sites-available/aether /etc/nginx/sites-enabled/aether
sudo nginx -t
sudo systemctl reload nginx
# 证书:certbot 会把上面这个站点改成 443 + 自动把 80 跳到 https
sudo certbot --nginx -d "$DOMAIN" -d "$WWW" --non-interactive --agree-tos --register-unsafely-without-email --redirect --keep-until-expiring
sudo nginx -t && sudo systemctl reload nginx

step "5/5 冒烟测试（不发消息，不在你们的聊天记录里留东西）"
S=$(grep '^RELAY_SECRET=' "$RELAY_DIR/relay.env" | cut -d= -f2-)
echo -n "healthz:          "; curl -fsS "https://$DOMAIN/relay/healthz"; echo
echo -n "history (带密钥):  "; curl -fsS -o /dev/null -w '%{http_code}\n' "https://$DOMAIN/relay/app/history?limit=1" -H "Authorization: Bearer $S"
echo -n "history (不带密钥): "; curl -sS -o /dev/null -w '%{http_code}  (应为 401)\n' "https://$DOMAIN/relay/app/history?limit=1"
echo -n "stream (SSE):     "; curl -sS -N --max-time 4 "https://$DOMAIN/relay/app/stream?token=$S" | head -c 60 | tr '\n' ' '; echo
echo -n "前端 /chat/:       "; curl -fsS -o /dev/null -w '%{http_code}\n' "https://$DOMAIN/chat/"
echo -n "http → https 跳转: "; curl -sS -o /dev/null -w '%{http_code} -> %{redirect_url}\n' "http://$DOMAIN/chat/"
echo -n "www 证书:          "; curl -fsS -o /dev/null -w '%{http_code}\n' "https://$WWW/chat/"
echo -n "relay 进程用户:     "; ps -o user= -p "$(systemctl show -p MainPID --value companion-relay)"

step "完成（Claude Code + channel 还没装）"
echo "手机打开：https://$DOMAIN/chat/  → 添加到主屏幕"
echo "登录密钥：grep RELAY_SECRET $RELAY_DIR/relay.env"
