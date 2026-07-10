#!/usr/bin/env bash
# ============================================================
# Claude Code + DeepSeek 一键安装（公司 Mac）
# 原理：DeepSeek 官方 /anthropic 端点原生支持 Anthropic 协议，
#       Claude Code 直连，零翻译层（区别于 codex-deploy 需要 ccx）。
# 用法： bash install.sh    （幂等，可重复运行）
# 依赖：Node.js 18+ + npm + curl（macOS 自带 curl）
# 安全：DeepSeek key 只写 ~/.claude-deepseek-env（权限 600），不进脚本/日志/仓库
# ============================================================
set -uo pipefail

BASE_URL="https://api.deepseek.com/anthropic"
MODEL="${CLAUDE_MODEL:-deepseek-v4-pro}"   # 省钱: export CLAUDE_MODEL=deepseek-v4-flash
ENV_FILE="${HOME}/.claude-deepseek-env"

G='\033[32m'; Y='\033[33m'; R='\033[31m'; N='\033[0m'
ok(){ printf "${G}✓${N} %s\n" "$1"; }
info(){ printf "  %s\n" "$1"; }
warn(){ printf "${Y}!${N} %s\n" "$1"; }
die(){ printf "${R}✗ %s${N}\n" "$1" >&2; exit 1; }

echo "=========================================="
echo "  Claude Code + DeepSeek 一键安装"
echo "=========================================="

# ---- 0. 前置：Node 18+ ----
echo "【0/4】检查环境..."
command -v node >/dev/null || die "缺 Node.js（装 Node 18+，找 IT 或 nvm install 18）"
NM="$(node -v | sed 's/v//;s/\..*//')"
[ "$NM" -ge 18 ] 2>/dev/null || die "Node 版本过低（$(node -v)），需 18+"
command -v npm  >/dev/null || die "缺 npm"
command -v curl >/dev/null || die "缺 curl"
ok "Node $(node -v) / npm $(npm -v)"

# ---- 1. 装/升级 Claude Code（npm 全局，幂等）----
echo "【1/4】安装 Claude Code..."
if ! npm install -g @anthropic-ai/claude-code >/dev/null 2>&1; then
  die "npm 安装失败（查网络/代理/npm 权限）"
fi
CCV="$(claude --version 2>/dev/null || echo '已装')"
ok "Claude Code ${CCV}"

# ---- 2. 收 DeepSeek key（不回显，不进脚本）----
echo "【2/4】填 DeepSeek API Key..."
warn "key 只写本地 ${ENV_FILE}（权限 600），不进脚本/日志/仓库"
while true; do
  printf "  粘贴 DeepSeek key（sk-...，输入不显示）: "; read -rs DK; echo
  case "$DK" in
    sk-*) break ;;
    "") warn "不能为空" ;;
    *) warn "应以 sk- 开头（你输入的开头是 '${DK:0:6}...')" ;;
  esac
done

# ---- 3. 持久化：独立 env 文件（chmod 600）+ zshrc 一行 source ----
echo "【3/4】持久化配置..."
umask 077
cat > "$ENV_FILE" <<EOF
# Claude Code -> DeepSeek（claude-code-deploy 生成）
# 换模型：改下面 MODEL 值后重开终端，或重跑 CLAUDE_MODEL=xxx bash install.sh
# 1M 上下文：模型名后加 [1m]，如 deepseek-v4-pro[1m]
export ANTHROPIC_BASE_URL="$BASE_URL"
export ANTHROPIC_AUTH_TOKEN="$DK"
export ANTHROPIC_MODEL="${MODEL}"
export ANTHROPIC_DEFAULT_OPUS_MODEL="${MODEL}"
export ANTHROPIC_DEFAULT_SONNET_MODEL="${MODEL}"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="deepseek-v4-flash"
export CLAUDE_CODE_SUBAGENT_MODEL="deepseek-v4-flash"
export CLAUDE_CODE_EFFORT_LEVEL="max"
EOF
chmod 600 "$ENV_FILE"
ok "配置写入 ${ENV_FILE}（权限 600）"

# 注入 zshrc（标记区块便卸载；key 不进 zshrc 明文，只 source env 文件）
touch "${HOME}/.zshrc"
LINE='[ -f "$HOME/.claude-deepseek-env" ] && . "$HOME/.claude-deepseek-env"'
if grep -qF '.claude-deepseek-env' "${HOME}/.zshrc" 2>/dev/null; then
  ok "~/.zshrc 已注入（跳过）"
else
  printf '\n# >>> claude-deepseek >>>\n%s\n# <<< claude-deepseek <<<\n' "$LINE" >> "${HOME}/.zshrc"
  ok "已注入 ~/.zshrc"
fi

# ---- 4. 自测（curl 打 DeepSeek /anthropic，绕开 claude 首次 onboarding）----
echo "【4/4】自测（打 DeepSeek /anthropic 端点）..."
. "$ENV_FILE"
TF="$(mktemp)"
CODE="$(curl -s -o "$TF" -w '%{http_code}' --max-time 25 \
  "${BASE_URL}/v1/messages" \
  -H "content-type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -H "Authorization: Bearer ${DK}" \
  -d '{"model":"'"${MODEL}"'","max_tokens":20,"messages":[{"role":"user","content":"say hi in 3 words"}]}')"
if [ "${CODE}" = "200" ]; then
  REPLY="$(python3 -c 'import json,sys
try: d=json.load(open(sys.argv[1])); print(d["content"][0]["text"])
except Exception: print("(解析失败)")' "$TF" 2>/dev/null | head -c 120)"
  ok "✅ DeepSeek /anthropic 打通（HTTP 200）"
  info "回复：${REPLY}"
else
  warn "自测 HTTP=${CODE}（401=key 错；000=网络不通；5xx=DeepSeek 端）"
  info "响应：$(head -c 200 "$TF")"
fi
rm -f "$TF"

cat <<EOF

${G}========================================================${N}
 完成！新开一个终端窗口，cd 到项目目录，跑：
   claude
 ${Y}不要登录 Anthropic 账号${N}（直接走 DeepSeek）
 首次跑 claude 会过一遍 onboarding（选主题/信任目录），按提示走即可。
 排错 / 换模型 / 卸载见 README.md
${G}========================================================${N}
EOF
