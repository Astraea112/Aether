#!/usr/bin/env bash
# Ombre Brain · 第 4 步：给服务器上的 Claude Code（~/orion）接上 Ombre Brain，然后重启 tmux 里的 orion。
# 在 OAO 上用 ubuntu 用户运行：bash ob-4-claude-code.sh        可以重复运行。
#
# 连接方式：本机回环 http://127.0.0.1:18001/mcp + 静态 token（hybrid 模式）。
#   - 服务器上没有浏览器，走不了 OAuth 回调；静态 token 不需要浏览器
#   - 不经过 nginx/证书/DNS，少几个故障点；token 不出这台机器
# 不碰 channel：不改 ~/orion/.mcp.json 和 ~/orion/.claude/settings.json。
#   MCP 用默认 local 作用域（写进 ~/.claude.json）；放行规则写在单独的 settings.local.json。
set -euo pipefail

WORK="$HOME/orion"
CLAUDE="$HOME/.local/bin/claude"
ENVF="$HOME/ombre-brain-deploy/.env"
URL="http://127.0.0.1:18001/mcp"

step(){ printf '\n\033[1m==== %s\033[0m\n' "$*"; }
ok(){ printf '\033[32m✓ %s\033[0m\n' "$*"; }
die(){ printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

step "0/4 预检"
[ "$(id -un)" = "ubuntu" ] || die "请用 ubuntu 用户运行（现在是 $(id -un)），不要加 sudo"
[ -x "$CLAUDE" ] || die "找不到 $CLAUDE"
[ -d "$WORK" ] || die "找不到 $WORK"
[ -x "$WORK/start-orion.sh" ] || die "找不到 $WORK/start-orion.sh"
TOKEN=$(grep -m1 '^OMBRE_MCP_TOKEN=' "$ENVF" | cut -d= -f2-)
[ -n "$TOKEN" ] || die "$ENVF 里没有 OMBRE_MCP_TOKEN，先跑 ob-2-deploy.sh"
curl -fsS http://127.0.0.1:18001/health >/dev/null || die "Ombre Brain 没在跑"
ok "都在"

step "1/4 claude mcp add（~/orion，local 作用域）"
cd "$WORK"
"$CLAUDE" mcp remove ombre-brain -s local >/dev/null 2>&1 || true
"$CLAUDE" mcp add -s local --transport http ombre-brain "$URL" --header "Authorization: Bearer $TOKEN" >/dev/null
# 只查 ombre-brain 这一个(不用 mcp list:它会顺带拉起 channel,可能截走正好到达的消息);不打印 token
"$CLAUDE" mcp get ombre-brain 2>&1 | grep -E 'Scope|Status|Type|URL' || true
"$CLAUDE" mcp get ombre-brain 2>&1 | grep -q 'Connected' || die "ombre-brain 没连上"
ok "已添加"

step "2/4 放行 Ombre Brain 的工具（没人值守时不卡在权限确认上）"
mkdir -p "$WORK/.claude"
python3 - "$WORK/.claude/settings.local.json" <<'PY'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1])
d = json.loads(p.read_text()) if p.exists() and p.read_text().strip() else {}
allow = d.setdefault("permissions", {}).setdefault("allow", [])
if "mcp__ombre-brain" not in allow:
    allow.append("mcp__ombre-brain")
p.write_text(json.dumps(d, ensure_ascii=False, indent=2) + "\n")
print(p, "→", allow)
PY

step "3/4 重启 tmux 里的 orion"
tmux kill-session -t orion 2>/dev/null || true
sleep 1
"$WORK/start-orion.sh"
sleep 4

step "4/4 看一眼它起来没有"
tmux has-session -t orion 2>/dev/null && ok "tmux 会话 orion 在运行" || die "orion 没起来：手动跑 $WORK/start-orion.sh"
tmux capture-pane -pt orion | tail -15
cat <<EOF

下一步你来确认：
  tmux attach -t orion
  在 Claude Code 里输入 /mcp 回车 → 列表里应有 companion 和 ombre-brain，都显示 connected
  按 Esc 关掉列表；离开但不关掉它：先按 Ctrl-b，再按 d
EOF
