#!/usr/bin/env bash
# 只更新网页（前端），别的都不动。在 OAO 上用 ubuntu 用户运行：
#   curl -fsSL https://raw.githubusercontent.com/Astraea112/Aether/skin/orion/deploy/update-web.sh | bash
# 可以重复运行。
set -euo pipefail
REF="${REF:-skin/orion}"
WEB_DIR=/var/www/companion-web
[ "$(id -un)" = "ubuntu" ] || { echo "✗ 请用 ubuntu 用户运行"; exit 1; }
tmp=$(mktemp -d)
git clone -q --depth 1 -b "$REF" https://github.com/Astraea112/Aether "$tmp/web"
grep -q 'const USE_MOCK  = false;' "$tmp/web/index.html" || { echo "✗ 这一版 USE_MOCK 不是 false，不更新"; exit 1; }
sudo rsync -a --delete --exclude '.git' --exclude 'deploy' --exclude 'design-refs' --exclude '*.md' --exclude 'LICENSE' --exclude 'NOTICE' "$tmp/web/" "$WEB_DIR/"
sudo chown -R www-data:www-data "$WEB_DIR"
v=$(git -C "$tmp/web" rev-parse --short HEAD); rm -rf "$tmp"
code=$(curl -s -o /dev/null -w '%{http_code}' https://oao0724.com/chat/)
[ "$code" = "200" ] && printf '\033[32m✓ 网页已更新到 %s\033[0m 手机上关掉再打开一次就是新的。\n' "$v" || { echo "✗ 网页打不开（$code）"; exit 1; }
