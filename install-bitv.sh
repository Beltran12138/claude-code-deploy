#!/usr/bin/env bash
# ============================================================
# Claude Code + BitV 一键安装（公司 Mac）
# 路径：claude → CCR(127.0.0.1:3457 gateway) → proxy(:8423) → BitV 网关
# 与 install.sh（DeepSeek 直连）并列，互不冲突：
#   - 不碰 ~/.zshrc（防 DeepSeek 场景污染）
#   - 配置进 ~/.claude-bitv-env（权限 600），由 ~/bin/claude-bitv 显式 source
# 用法： bash install-bitv.sh   （幂等）
# 前置：Node 18+ / npm / git / CCR（claude-code-router，npm 包 @musistudio/claude-code-router）
#       BitV key（向何总申请，sk- 开头）
# 实证：CCR config 结构 + 端口 3457（Qoder 2026-07-20）；billing 禁用=改 gateway.config.json
# ============================================================
set -uo pipefail

CCR_GATEWAY_PORT=3457          # CCR gateway（处理 /v1/messages 的真入口；3456/3459 是管理 UI）
PROXY_PORT=8423
PROXY_RAW="https://raw.githubusercontent.com/Beltran12138/chat-path-rewrite-proxy/main"
PROXY_CLONE_DIR="$HOME/chat-path-rewrite-proxy"
CCR_DIR="$HOME/.claude-code-router"
ENV_FILE="$HOME/.claude-bitv-env"
LAUNCHER="$HOME/bin/claude-bitv"
CCR_PLIST="$HOME/Library/LaunchAgents/com.local.ccr.plist"
CCR_TOKEN_FILE="$CCR_DIR/.ccr-gateway-token"

G='\033[32m'; Y='\033[33m'; R='\033[31m'; N='\033[0m'
ok(){ printf "${G}✓${N} %s\n" "$1"; }
info(){ printf "  %s\n" "$1"; }
warn(){ printf "${Y}!${N} %s\n" "$1"; }
die(){ printf "${R}✗ %s${N}\n" "$1" >&2; exit 1; }

echo "=========================================="
echo "  Claude Code + BitV 一键安装"
echo "=========================================="

# ---- 0. 前置 ----
echo "【0/6】检查环境..."
command -v node >/dev/null || die "缺 Node.js（装 Node 18+）"
NM="$(node -v | sed 's/v//;s/\..*//')"
[ "$NM" -ge 18 ] 2>/dev/null || die "Node 版本过低（$(node -v)），需 18+"
command -v npm >/dev/null || die "缺 npm"
command -v git >/dev/null || die "缺 git"
ok "Node $(node -v) / npm $(npm -v)"

# CCR 前置（检测，不自动装 —— CCR 是通用工具，版本迭代快，留给用户/IT）
if ! command -v ccr >/dev/null 2>&1; then
  warn "未检测到 CCR（claude-code-router）。请先装："
  info "  npm install -g @musistudio/claude-code-router   # 包名待你核（npm view）"
  info "  装完重跑本脚本"
  die "CCR 是 BitV 路径必需的翻译层（Anthropic→Chat）"
fi
ok "CCR 已装：$(ccr -v 2>/dev/null || echo '已装')"

# ---- 1. 装/升级 Claude Code ----
echo "【1/6】安装 Claude Code..."
npm install -g @anthropic-ai/claude-code >/dev/null 2>&1 || die "npm 装 claude-code 失败（查网络/代理）"
ok "Claude Code $(claude --version 2>/dev/null || echo '已装')"

# ---- 2. 拉起 proxy（检测 :8423，没活则 clone + install-proxy.sh）----
echo "【2/6】确保 proxy 在跑（:8423）..."
if curl -fsS -m 3 "http://localhost:${PROXY_PORT}/v1/models" >/dev/null 2>&1 \
   || nc -z 127.0.0.1 ${PROXY_PORT} 2>/dev/null; then
  ok "proxy 已在 :${PROXY_PORT}（跳过安装）"
else
  warn "proxy 未跑，开始装..."
  # 公司网封 github（git clone 挂）→ raw 拉 proxy 三文件；每次强制覆盖，防复用旧/损坏文件
  mkdir -p "$PROXY_CLONE_DIR"
  for f in install-proxy.sh proxy.js package.json; do
    curl -fsSL "$PROXY_RAW/$f" -o "$PROXY_CLONE_DIR/$f" || die "拉取 proxy/$f 失败（raw 连通？）"
  done
  info "跑 proxy 的 install-proxy.sh（会让你粘 BitV key）..."
  bash "$PROXY_CLONE_DIR/install-proxy.sh" || die "proxy 安装失败，见上方输出"
  ok "proxy 已装并自启"
fi

# ---- 3. 生成 CCR token + 写 CCR config ----
echo "【3/6】配 CCR（端口 ${CCR_GATEWAY_PORT}，禁 billing）..."
mkdir -p "$CCR_DIR"
umask 077
# 生成或复用 CCR gateway token（保护本地 :3457，非 BitV key）
if [ ! -s "$CCR_TOKEN_FILE" ]; then
  openssl rand -hex 32 > "$CCR_TOKEN_FILE" 2>/dev/null || die "openssl 生成 token 失败"
fi
CCR_TOKEN="$(cat "$CCR_TOKEN_FILE")"

# config-router.json（路由：defaultProvider→bitv-glm→:8423）
cat > "$CCR_DIR/config-router.json" <<EOF
{
  "server": { "host": "127.0.0.1", "port": 3459 },
  "routing": {
    "defaultProvider": "bitv-glm",
    "providers": {
      "bitv-glm": {
        "type": "openai",
        "endpoint": "http://127.0.0.1:${PROXY_PORT}",
        "authentication": { "credentials": { "apiKey": "dummy-key" } }
      }
    }
  },
  "rules": []
}
EOF

# gateway.config.json（billing=false 必需；models 用 Claude Code 2.1+ 新短名）
cat > "$CCR_DIR/gateway.config.json" <<EOF
{
  "auth": {
    "enabled": true, "mode": "static_api_key", "required": true,
    "staticApiKeys": {
      "keyBearerOnly": false,
      "keyEnv": "CCR_CORE_GATEWAY_AUTH_TOKEN",
      "keyHeader": "x-ccr-core-auth",
      "keys": ["${CCR_TOKEN}"]
    }
  },
  "billing": { "enabled": false },
  "billingQueue": { "enabled": false },
  "billingWebhook": { "enabled": false },
  "host": "127.0.0.1",
  "port": ${CCR_GATEWAY_PORT},
  "upstreamTimeoutMs": 600000,
  "providers": [{
    "name": "bitv::openai_chat_completions",
    "type": "openai_chat_completions",
    "apikey": "dummy-proxy-injects-real-key",
    "baseurl": "http://localhost:${PROXY_PORT}/v1",
    "models": [
      "claude-opus-4-8", "claude-sonnet-5", "claude-haiku-4-5",
      "claude-sonnet-4-5", "claude-haiku-4-5-20251001", "glm4.7"
    ]
  }]
}
EOF
ok "CCR config 已写（billing 已禁用）"

# ---- 4. 启/重启 CCR（让 config 生效）+ launchd 自启 ----
echo "【4/6】启/重启 CCR..."
# 若已有 launchd，先卸载再装（幂等）；否则尝试 ccr 命令 + 写 launchd
launchctl unload "$CCR_PLIST" 2>/dev/null || true
CCR_BIN="$(command -v ccr)"
# launchd 不带 login shell 的 PATH → nvm/homebrew 装的 node 找不到 → ccr 起不来
# 必须显式注入 PATH（Qoder 2026-07-20 实证：plist 不补 PATH 则 CCR launchd 启动失败）
NODE_DIR="$(dirname "$(command -v node)")"
USER_PATH="${NODE_DIR}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
cat > "$CCR_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.local.ccr</string>
  <key>ProgramArguments</key>
  <array><string>${CCR_BIN}</string><string>start</string></array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>${USER_PATH}</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>${CCR_DIR}/ccr.out.log</string>
  <key>StandardErrorPath</key><string>${CCR_DIR}/ccr.err.log</string>
</dict></plist>
EOF
launchctl load "$CCR_PLIST" 2>/dev/null && ok "CCR launchd 已加载（开机自启）" \
  || warn "launchd 加载失败，手动试：ccr start"
sleep 3

# ---- 5. 写 ~/.claude-bitv-env + launcher ----
echo "【5/6】写 launcher claude-bitv..."
umask 077
cat > "$ENV_FILE" <<EOF
# Claude Code -> BitV（install-bitv.sh 生成；权限 600）
# 不进 ~/.zshrc —— 由 ~/bin/claude-bitv 显式 source，防 DeepSeek 场景污染
export ANTHROPIC_BASE_URL="http://127.0.0.1:${CCR_GATEWAY_PORT}"
export ANTHROPIC_AUTH_TOKEN="${CCR_TOKEN}"
unset ANTHROPIC_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL 2>/dev/null || true
EOF
chmod 600 "$ENV_FILE"

mkdir -p "$(dirname "$LAUNCHER")"
cat > "$LAUNCHER" <<'EOF'
#!/usr/bin/env bash
# BitV 场景启动器：source 隔离 env + 启 claude
[ -f "$HOME/.claude-bitv-env" ] && . "$HOME/.claude-bitv-env" \
  || { echo "❌ 找不到 ~/.claude-bitv-env，先跑 install-bitv.sh" >&2; exit 1; }
exec claude "$@"
EOF
chmod +x "$LAUNCHER"
ok "launcher 已装：$LAUNCHER"
warn "确保 $(dirname "$LAUNCHER") 在 PATH（否则用全路径调）"

# ---- 6. 自测（curl 打 CCR gateway /v1/messages）----
echo "【6/6】自测 CCR gateway :${CCR_GATEWAY_PORT}..."
. "$ENV_FILE"
TF="$(mktemp)"
CODE="$(curl -s -o "$TF" -w '%{http_code}' --max-time 40 \
  "http://127.0.0.1:${CCR_GATEWAY_PORT}/v1/messages" \
  -H "content-type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -H "Authorization: Bearer ${ANTHROPIC_AUTH_TOKEN}" \
  -d '{"model":"claude-sonnet-5","max_tokens":20,"messages":[{"role":"user","content":"say hi in 3 words"}]}')"
if [ "$CODE" = "200" ]; then
  ok "✅ BitV 经 CCR 打通（HTTP 200，proxy 重写为 glm4.7）"
else
  warn "自测 HTTP=${CODE}（401=CCR token 不匹配；000=CCR 没起；5xx=proxy/网关）"
  info "响应：$(head -c 200 "$TF")"
  info "查 CCR 日志：tail -50 $CCR_DIR/ccr.err.log"
fi
rm -f "$TF"

# billing 持久化坑（Qoder 2026-07-20 实证）：CCR 重启从 SQLite 恢复，会覆盖 gateway.config.json 的 billing=false
warn "billing 已在 gateway.config.json 设 false，但 CCR 重启会从 SQLite 恢复覆盖它"
info "为确保 billing 真关闭 + 默认渠道=bitv-glm，装完去 CCR Web UI 手动确认一次："
info "  http://localhost:3458  （端口以你机器 CCR 实际占用为准；可能 3456/3458/3459）"
info "  确认两项：billing 已关闭 / 默认渠道 = bitv-glm"

cat <<EOF

${G}========================================================${N}
 完成！新开终端，cd 到项目目录，跑：
   claude-bitv
 ${Y}不要登录 Anthropic 账号${N}（直接走 BitV）
 首次会过 onboarding（选主题/信任目录），按提示走。
 与 DeepSeek 场景互不冲突：DeepSeek 用 claude，BitV 用 claude-bitv。
${G}========================================================${N}
EOF
