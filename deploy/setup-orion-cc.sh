#!/usr/bin/env bash
# Orion on the VPS: Claude Code + the Tidal_Echo channel plugin. Run after deploy-aether.sh, as `ubuntu`:
#     curl -fsSL https://raw.githubusercontent.com/Astraea112/Aether/skin/orion/deploy/setup-orion-cc.sh -o setup-orion-cc.sh
#     bash setup-orion-cc.sh
# It installs and configures everything, then stops before the first Claude Code login (that needs you).
# Safe to re-run.
set -euo pipefail

DOMAIN="oao0724.com"
AI_NAME="Orion"
HUMAN_NAME="Astraea"
RELAY_ENV="$HOME/companion-relay/relay.env"
CHANNEL_DIR="$HOME/companion-channel"
STATE_DIR="$HOME/.claude/channels/companion"
WORK="$HOME/orion"
BACKEND_REPO=https://github.com/anhe2021212-spec/Tidal_Echo
BUN="$HOME/.bun/bin/bun"
CLAUDE="$HOME/.local/bin/claude"

step(){ printf '\n\033[1m==== %s\033[0m\n' "$*"; }
die(){ printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

step "0/5 预检"
[ "$(id -un)" = "ubuntu" ] || die "请用 ubuntu 用户运行（现在是 $(id -un)），不要加 sudo"
[ -f "$RELAY_ENV" ] || die "找不到 $RELAY_ENV，先跑 deploy-aether.sh"
curl -fsS --max-time 10 "https://$DOMAIN/relay/healthz" && echo || die "https://$DOMAIN/relay 不通"

step "1/5 tmux"
sudo apt-get install -y tmux unzip >/dev/null
tmux -V

step "2/5 Bun（channel 插件的运行时）"
[ -x "$BUN" ] || curl -fsSL https://bun.sh/install | bash
"$BUN" --version

step "3/5 Claude Code"
[ -x "$CLAUDE" ] || curl -fsSL https://claude.ai/install.sh | bash
"$CLAUDE" --version
grep -q 'HOME/.local/bin' "$HOME/.bashrc" || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"

step "4/5 channel 插件"
tmp=$(mktemp -d)
git clone --depth 1 "$BACKEND_REPO" "$tmp/te"
mkdir -p "$CHANNEL_DIR"
cp "$tmp/te/channel/server.ts" "$tmp/te/channel/package.json" "$CHANNEL_DIR/"
rm -rf "$tmp"
(cd "$CHANNEL_DIR" && "$BUN" install --no-summary)
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
SECRET=$(grep '^RELAY_SECRET=' "$RELAY_ENV" | cut -d= -f2-)
[ -n "$SECRET" ] || die "relay.env 里没有 RELAY_SECRET"
umask 077
cat > "$STATE_DIR/.env" <<EOF
RELAY_SECRET=$SECRET
RELAY_URL=https://$DOMAIN/relay
RELAY_AI_NAME=$AI_NAME
RELAY_HUMAN_NAME=$HUMAN_NAME
RELAY_CHANNEL_NAME=companion
EOF
umask 022
echo "channel 配置：$STATE_DIR/.env（密钥和 relay 同一把，只有你能读）"

step "5/5 Orion 的工作目录 $WORK"
mkdir -p "$WORK/.claude"
# 直接用绝对路径跑 server.ts:Claude Code 拉起的子进程不一定有 ~/.bun/bin 在 PATH 里
cat > "$WORK/.mcp.json" <<EOF
{
  "mcpServers": {
    "companion": {
      "command": "$BUN",
      "args": ["$CHANNEL_DIR/server.ts"]
    }
  }
}
EOF
# 放行 channel 的三个工具,否则每次回复都要人点确认,没人值守时会卡住
[ -f "$WORK/.claude/settings.json" ] || cat > "$WORK/.claude/settings.json" <<'EOF'
{
  "enabledMcpjsonServers": ["companion"],
  "permissions": {
    "allow": ["mcp__companion__reply", "mcp__companion__react", "mcp__companion__call"]
  }
}
EOF
cat > "$WORK/start-orion.sh" <<EOF
#!/usr/bin/env bash
# (Re)start Orion inside tmux session "orion" and auto-confirm the dev-channel warning.
if tmux has-session -t orion 2>/dev/null; then echo "orion 已经在运行：tmux attach -t orion"; exit 0; fi
tmux new-session -d -s orion -c "$WORK" "$CLAUDE --dangerously-load-development-channels server:companion"
for i in \$(seq 1 8); do sleep 2; tmux send-keys -t orion Enter; done
echo "已启动。看它：tmux attach -t orion（离开但不关掉：先按 Ctrl-b，再按 d）"
EOF
chmod +x "$WORK/start-orion.sh"
ls -la "$WORK" "$WORK/.claude"

step "装好了。下一步要你来：第一次登录 Claude Code"
cat <<EOF
依次输入：
  tmux new -s orion -c $WORK
  $CLAUDE --dangerously-load-development-channels server:companion
然后按屏幕提示：选主题 → 选用 Claude 账号登录 → 打开它给的链接授权 → 把授权码粘回来
→ 信任这个文件夹（Yes）→ 开发 channel 警告选 1（I am using this for local development）
看到 [companion:boot] connected ... 就是连上了。
离开但不关掉它：先按 Ctrl-b，再按 d。以后重启用：$WORK/start-orion.sh
EOF
