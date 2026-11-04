#!/usr/bin/env bash
# Ombre Brain · 第 1 步：装 Docker 和 docker compose（已经装了就跳过）。
# 在 OAO 上用 ubuntu 用户运行：bash ob-1-docker.sh      可以重复运行。
set -euo pipefail

step(){ printf '\n\033[1m==== %s\033[0m\n' "$*"; }
ok(){ printf '\033[32m✓ %s\033[0m\n' "$*"; }
die(){ printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -un)" = "${RUN_AS:-ubuntu}" ] || die "请用 ubuntu 用户运行（现在是 $(id -un)），不要加 sudo"
# apt 装完东西时 Ubuntu 会弹"Daemons using outdated libraries"问要不要重启服务；
# 这里让它只列出、不弹框（不重启任何服务，下次开机自然生效）
APT=(sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l NEEDRESTART_SUSPEND=1 apt-get -y)

step "1/3 看看是不是已经装好了"
if command -v docker >/dev/null 2>&1 && sudo docker compose version >/dev/null 2>&1; then
  ok "已安装：$(sudo docker --version)；compose $(sudo docker compose version --short)"
elif command -v docker >/dev/null 2>&1; then
  step "2/3 有 Docker 但缺 compose 插件，补上"
  "${APT[@]}" update
  "${APT[@]}" install docker-compose-plugin || "${APT[@]}" install docker-compose-v2
else
  step "2/3 从 Docker 官方源安装"
  . /etc/os-release
  "${APT[@]}" update
  "${APT[@]}" install ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME:-$VERSION_CODENAME} stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  "${APT[@]}" update
  "${APT[@]}" install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
sudo systemctl enable --now docker >/dev/null 2>&1 || true

step "3/3 验证"
sudo docker compose version
sudo docker run --rm hello-world >/dev/null && ok "Docker 能正常跑容器"
echo "内存情况（OB 空闲时大约占 90MB）："
free -m | sed -n '1,2p'
ok "第 1 步完成"
