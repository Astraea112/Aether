#!/usr/bin/env bash
# Ombre Brain · 第 3 步：nginx 给 brain.oao0724.com 反代到 127.0.0.1:18001，certbot 签证书。
# 在 OAO 上用 ubuntu 用户运行：bash ob-3-nginx.sh        可以重复运行。
# 只新增 /etc/nginx/sites-available/ombre-brain，不碰 oao0724.com 的站点和证书；改动前先整体备份 /etc/nginx。
set -euo pipefail

DOMAIN="${DOMAIN:-brain.oao0724.com}"
SITE=/etc/nginx/sites-available/ombre-brain
MAIN_SITE=/etc/nginx/sites-available/aether
PORT=18001

step(){ printf '\n\033[1m==== %s\033[0m\n' "$*"; }
ok(){ printf '\033[32m✓ %s\033[0m\n' "$*"; }
die(){ printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

step "0/4 预检"
[ "$(id -un)" = "ubuntu" ] || die "请用 ubuntu 用户运行（现在是 $(id -un)），不要加 sudo"
MYIP=$(curl -fsS --max-time 10 https://api.ipify.org || true)
DNSIP=$(getent ahostsv4 "$DOMAIN" | awk 'NR==1{print $1}' || true)
echo "本机公网 IP：${MYIP:-未知}    $DOMAIN 解析到：${DNSIP:-（没解析）}"
[ -n "$DNSIP" ] && [ "$DNSIP" = "$MYIP" ] || die "$DOMAIN 还没指向这台机器：先去腾讯云 DNS 加 A 记录，等几分钟再跑"
curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null || die "Ombre Brain 没在跑，先跑 ob-2-deploy.sh"
MAIN_SUM=$(sudo md5sum "$MAIN_SITE" 2>/dev/null | cut -d' ' -f1 || echo none)
BK="/home/ubuntu/nginx-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
sudo tar czf "$BK" -C /etc nginx && sudo chown ubuntu:ubuntu "$BK"
ok "已备份 /etc/nginx → $BK"

step "1/4 nginx 站点 $DOMAIN"
if sudo test -f "$SITE" && sudo grep -q ssl_certificate "$SITE"; then
  ok "站点已经配过证书，不覆盖"
else
  sudo tee "$SITE" >/dev/null <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    client_max_body_size 50m;

    # 按 Ombre Brain README 的反代写法:把浏览器看到的公网来源原样传过去
    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_buffering off;
        proxy_read_timeout 3600s;
    }
}
NGINX
  ok "已写入 $SITE"
fi
sudo ln -sf "$SITE" /etc/nginx/sites-enabled/ombre-brain
sudo nginx -t
sudo systemctl reload nginx

step "2/4 证书（只签 $DOMAIN）"
sudo certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email --redirect --keep-until-expiring
sudo nginx -t && sudo systemctl reload nginx
echo | openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" 2>/dev/null | openssl x509 -noout -subject -enddate -ext subjectAltName

step "3/4 检查 brain"
echo -n "https 健康检查：      "; curl -fsS "https://$DOMAIN/health"; echo
echo -n "OAuth 地址：          "; curl -fsS "https://$DOMAIN/.well-known/oauth-authorization-server" | python3 -c "import sys,json; print(json.load(sys.stdin)['issuer'])"
echo -n "http → https：        "; curl -sS -o /dev/null -w '%{http_code} → %{redirect_url}\n' "http://$DOMAIN/health"
echo -n "/mcp 不带授权：       "; curl -sS -o /dev/null -w '%{http_code}（应为 401）\n' -X POST "https://$DOMAIN/mcp" -H 'Content-Type: application/json' -d '{}'
echo -n "授权页：              "; curl -sS -o /dev/null -w '%{http_code}\n' "https://$DOMAIN/dashboard"

step "4/4 原来的站点没受影响"
NOW_SUM=$(sudo md5sum "$MAIN_SITE" 2>/dev/null | cut -d' ' -f1 || echo none)
[ "$NOW_SUM" = "$MAIN_SUM" ] && ok "oao0724.com 的 nginx 配置文件没有被改动" || die "oao0724.com 的配置被改了！可以从 $BK 恢复"
echo -n "relay 健康检查：      "; curl -fsS https://oao0724.com/relay/healthz; echo
echo -n "前端 /chat/：         "; curl -fsS -o /dev/null -w '%{http_code}\n' https://oao0724.com/chat/
ok "第 3 步完成：https://$DOMAIN/dashboard 可以用 Dashboard 密码登录"
