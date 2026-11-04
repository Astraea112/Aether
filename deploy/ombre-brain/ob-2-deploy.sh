#!/usr/bin/env bash
# Ombre Brain · 第 2 步：用官方镜像部署，端口只绑 127.0.0.1:18001，数据在 /home/ubuntu/ombre-brain。
# 在 OAO 上用 ubuntu 用户运行：bash ob-2-deploy.sh            可以重复运行，不会丢数据、不会换密码。
#   以后要换 / 补 Gemini key：bash ob-2-deploy.sh --gemini
#
# 做的事：
#   - 配置和密钥放在 /home/ubuntu/ombre-brain-deploy/.env（只有 ubuntu 能读，不进 git）
#   - Dashboard 密码：你来设（直接回车就随机生成）；MCP 静态 token：随机生成，给服务器上的 Claude Code 用
#   - 首次启动前预置 config.yaml：公网地址 https://brain.oao0724.com（OAuth 地址以它为准）、AI 名字 Orion
#   - 鉴权模式 hybrid：claude.ai 走 OAuth，服务器上的 Claude Code 走静态 token
#   - 可信反代 = 本机回环 + Docker 网桥网关 172.30.18.1（nginx 经 docker-proxy 进来时容器看到的就是它）
#   - 不配置 GitHub 同步，不启用 Cloudflare Tunnel
set -euo pipefail

PUBLIC_URL="${PUBLIC_URL:-https://brain.oao0724.com}"
VAULT="${VAULT:-/home/ubuntu/ombre-brain}"
DEPLOY="${DEPLOY:-/home/ubuntu/ombre-brain-deploy}"
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/Astraea112/Aether/skin/orion/deploy/ombre-brain}"
TAG="${TAG:-3.6.14}"
PORT=18001
SUBNET=172.30.18.0/24
GATEWAY=172.30.18.1
AI_NAME=Orion
GEMINI_BASE=https://generativelanguage.googleapis.com/v1beta/openai/
ENVF="$DEPLOY/.env"

step(){ printf '\n\033[1m==== %s\033[0m\n' "$*"; }
ok(){ printf '\033[32m✓ %s\033[0m\n' "$*"; }
warn(){ printf '\033[33m! %s\033[0m\n' "$*"; }
die(){ printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
getenv(){ [ -f "$ENVF" ] && grep -m1 "^$1=" "$ENVF" | cut -d= -f2- || true; }
setenv(){  # 安全地改 .env 里的一行（值里有特殊字符也不怕）
  python3 - "$ENVF" "$1" "$2" <<'PY'
import sys, pathlib
p, k, v = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
lines = p.read_text().splitlines() if p.exists() else []
out, done = [], False
for l in lines:
    if l.startswith(k + "="):
        if not done: out.append(f"{k}={v}"); done = True
    else: out.append(l)
if not done: out.append(f"{k}={v}")
p.write_text("\n".join(out) + "\n")
PY
  chmod 600 "$ENVF"
}
ask_gemini(){
  echo "去 Google AI Studio（https://aistudio.google.com/apikey）创建一个 API key，粘贴到这里。"
  echo "输入时屏幕上不会显示字符，这是正常的。暂时没有就直接回车跳过（之后用 --gemini 再填）。"
  read -rsp "Gemini API key: " key; echo
  if [ -n "$key" ]; then
    setenv OMBRE_COMPRESS_API_KEY "$key"
    setenv OMBRE_EMBED_API_KEY "$key"
    ok "已写入 $ENVF（压缩和向量化共用这一把）"
  else
    warn "跳过：没有 key 时能存能读，但 hold 打标/语义检索会降级"
  fi
}

step "0/5 预检"
[ "$(id -un)" = "${RUN_AS:-ubuntu}" ] || die "请用 ubuntu 用户运行（现在是 $(id -un)），不要加 sudo"
sudo docker compose version >/dev/null 2>&1 || die "还没装 docker compose，先跑 ob-1-docker.sh"
if ip -4 route | grep -v -E 'docker0|br-' | grep -q '^172\.30\.18\.'; then
  die "172.30.18.0/24 和这台机器现有网络冲突，需要换一个网段（告诉 Claude）"
fi
others=$(sudo docker network ls -q | xargs -r sudo docker network inspect --format '{{.Name}} {{range .IPAM.Config}}{{.Subnet}} {{end}}' | grep " $SUBNET" | grep -v '^ombre-brain_ombre ' || true)
[ -z "$others" ] || die "已有别的 Docker 网络占用 $SUBNET：$others"
if sudo ss -ltnH "sport = :$PORT" | grep -q . && ! sudo docker ps --format '{{.Names}}' | grep -qx ombre-brain; then
  die "端口 $PORT 已被别的程序占用"
fi
ok "网段、端口都没冲突"

step "1/5 目录和 compose 文件"
mkdir -p "$VAULT" "$DEPLOY"
chmod 700 "$VAULT" "$DEPLOY"
curl -fsSL "$REPO_RAW/docker-compose.yml" -o "$DEPLOY/docker-compose.yml.new"
mv "$DEPLOY/docker-compose.yml.new" "$DEPLOY/docker-compose.yml"
ok "数据目录 $VAULT ；部署目录 $DEPLOY"

step "2/5 .env（密码、token、Gemini key）"
umask 077
if [ ! -f "$ENVF" ]; then
  echo "给 Dashboard 设一个密码（也是 claude.ai 授权时要输的那个）。输入时不显示，直接回车则随机生成。"
  read -rsp "Dashboard 密码: " p1; echo
  if [ -n "$p1" ]; then
    read -rsp "再输一遍: " p2; echo
    [ "$p1" = "$p2" ] || die "两次不一样，重新运行本脚本"
    [ ${#p1} -ge 10 ] || die "至少 10 位，重新运行本脚本"
    DASH="$p1"
  else
    DASH=$(python3 -c "import secrets; print(secrets.token_urlsafe(18))")
    echo "已随机生成。之后查看：grep OMBRE_DASHBOARD_PASSWORD $ENVF"
  fi
  : > "$ENVF"
  setenv OMBRE_HOST_VAULT_DIR "$VAULT"
  setenv OMBRE_IMAGE_TAG "$TAG"
  setenv OMBRE_DASHBOARD_PASSWORD "$DASH"
  setenv OMBRE_MCP_AUTH_MODE hybrid
  setenv OMBRE_MCP_TOKEN "$(python3 -c "import secrets; print(secrets.token_urlsafe(36))")"
  setenv OMBRE_COMPRESS_API_KEY ""
  setenv OMBRE_COMPRESS_BASE_URL "$GEMINI_BASE"
  setenv OMBRE_COMPRESS_MODEL gemini-2.5-flash-lite
  setenv OMBRE_EMBED_API_KEY ""
  setenv OMBRE_EMBED_BASE_URL "$GEMINI_BASE"
  setenv OMBRE_EMBED_MODEL gemini-embedding-001
  setenv AI_NAME "$AI_NAME"
  setenv OMBRE_TRUSTED_PROXY_CIDRS "127.0.0.0/8,::1/128,$GATEWAY/32"
  ok "已生成 $ENVF"
  ask_gemini
else
  ok "$ENVF 已存在：保留原来的密码和 token"
  setenv OMBRE_IMAGE_TAG "$TAG"
  if [ "${1:-}" = "--gemini" ] || [ -z "$(getenv OMBRE_EMBED_API_KEY)" ]; then ask_gemini; fi
fi
umask 022
KEY=$(getenv OMBRE_EMBED_API_KEY)
if [ -n "$KEY" ]; then
  code=$(curl -sS -o /tmp/ob-embed-test.json -w '%{http_code}' --max-time 30 "${GEMINI_BASE}embeddings" \
    -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
    -d '{"model":"gemini-embedding-001","input":"ping"}' || echo 000)
  if [ "$code" = 200 ]; then ok "Gemini key 有效（gemini-embedding-001 调用成功）"
  else warn "Gemini key 测试失败（HTTP $code）：$(tr -s "\n " " " < /tmp/ob-embed-test.json 2>/dev/null | head -c 240)"; fi
  rm -f /tmp/ob-embed-test.json
fi

step "3/5 预置 config.yaml（只在第一次；之后不覆盖你在 Dashboard 里的改动）"
sudo docker pull -q "p0luz/ombre-brain:$TAG" >/dev/null
if ! sudo test -f "$VAULT/config.yaml"; then
  sudo docker run --rm --entrypoint cat "p0luz/ombre-brain:$TAG" /app/config.default.yaml > /tmp/ob-config.yaml
  grep -q '^  public_url: ""' /tmp/ob-config.yaml || die "默认配置里找不到 public_url（镜像版本变了？）"
  sed -i "s#^  public_url: \"\"#  public_url: \"$PUBLIC_URL\"#; s#^ai_name: \"\"#ai_name: \"$AI_NAME\"#" /tmp/ob-config.yaml
  sudo mv /tmp/ob-config.yaml "$VAULT/config.yaml"
  ok "已写入 $VAULT/config.yaml"
else
  if sudo grep -q '^  public_url: ""' "$VAULT/config.yaml"; then
    sudo sed -i "s#^  public_url: \"\"#  public_url: \"$PUBLIC_URL\"#" "$VAULT/config.yaml"
    ok "补上了 public_url"
  else
    ok "config.yaml 已存在，不动"
  fi
fi
sudo grep -n 'public_url:' "$VAULT/config.yaml" | head -1

step "4/5 启动容器"
cd "$DEPLOY"
sudo docker compose up -d
for i in $(seq 1 30); do curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break; sleep 2; done

step "5/5 检查"
echo -n "健康检查：            "; curl -fsS "http://127.0.0.1:$PORT/health" || die "容器没起来：sudo docker logs --tail 50 ombre-brain"
echo
echo -n "OAuth 地址：          "; issuer=$(curl -fsS "http://127.0.0.1:$PORT/.well-known/oauth-authorization-server" | python3 -c "import sys,json; print(json.load(sys.stdin)['issuer'])")
echo "$issuer"; [ "$issuer" = "$PUBLIC_URL" ] || die "OAuth 地址不对，应该是 $PUBLIC_URL"
echo -n "/mcp 不带 token：      "; curl -sS -o /dev/null -w '%{http_code}（应为 401）\n' -X POST "http://127.0.0.1:$PORT/mcp" -H 'Content-Type: application/json' -d '{}'
echo -n "/mcp 带静态 token：    "
python3 - "$PORT" "$(getenv OMBRE_MCP_TOKEN)" <<'PY'
import json, sys, urllib.request
port, tok = sys.argv[1], sys.argv[2]
def call(body, sid=None):
    h = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream", "Authorization": "Bearer " + tok}
    if sid: h["Mcp-Session-Id"] = sid
    r = urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:{port}/mcp", json.dumps(body).encode(), h, method="POST"), timeout=20)
    raw = r.read().decode()
    data = next((l[6:] for l in raw.splitlines() if l.startswith("data: ")), raw)
    return (json.loads(data) if data.strip() else {}), r.headers.get("Mcp-Session-Id") or sid
_, sid = call({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"ob-check","version":"0"}}})
call({"jsonrpc":"2.0","method":"notifications/initialized"}, sid)
res, _ = call({"jsonrpc":"2.0","id":2,"method":"tools/list"}, sid)
names = [t["name"] for t in res["result"]["tools"]]
print(f"{len(names)} 个工具，breath={'breath' in names} hold={'hold' in names}")
PY
sudo docker stats --no-stream --format '内存：{{.MemUsage}}' ombre-brain
ok "第 2 步完成。Dashboard 密码：grep OMBRE_DASHBOARD_PASSWORD $ENVF"
