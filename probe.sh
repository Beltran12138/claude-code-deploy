#!/usr/bin/env bash
# ============================================================
# probe.sh —— 装机前只读环境探测（不改任何东西，不收 key）
# 用法： bash probe.sh
# ============================================================
set -uo pipefail

G='\033[32m'; Y='\033[33m'; R='\033[31m'; N='\033[0m'

echo "=========================================="
echo "  Claude Code + DeepSeek 环境探测（只读）"
echo "=========================================="
echo "系统：$(uname -s) $(uname -m)"

# Node
if command -v node >/dev/null; then
  NM="$(node -v | sed 's/v//;s/\..*//')"
  if [ "$NM" -ge 18 ] 2>/dev/null; then
    printf "${G}✓${N} Node %s（≥18，达标）\n" "$(node -v)"
  else
    printf "${R}✗${N} Node %s（需 18+，找 IT 或 nvm install 18）\n" "$(node -v)"
  fi
else
  printf "${R}✗${N} Node 未安装（需 18+）\n"
fi

# npm
command -v npm >/dev/null && printf "${G}✓${N} npm %s\n" "$(npm -v)" || printf "${R}✗${N} npm 未安装\n"

# git
command -v git >/dev/null && printf "${G}✓${N} git %s\n" "$(git --version | awk '{print $3}')" || printf "${R}✗${N} git 未安装\n"

# curl
command -v curl >/dev/null && printf "${G}✓${N} curl 已装\n" || printf "${R}✗${N} curl 未装\n"

# Claude Code 是否已装
if command -v claude >/dev/null; then
  printf "${G}✓${N} Claude Code 已装：%s\n" "$(claude --version 2>/dev/null || echo '版本未知')"
else
  printf "${Y}!${N} Claude Code 未装（install.sh 会自动装）\n"
fi

# 是否已配置 DeepSeek
if [ -f "${HOME}/.claude-deepseek-env" ]; then
  printf "${Y}!${N} 已有配置 ~/.claude-deepseek-env（重跑 install.sh 会覆盖 key）\n"
else
  printf "  未配置（install.sh 会生成）\n"
fi

# DeepSeek 连通性（不打 key，只探端点）
printf "  DeepSeek 端点连通："
HC="$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 https://api.deepseek.com/ 2>/dev/null || echo '不通')"
if [ "$HC" = "000" ] || [ "$HC" = "不通" ]; then
  printf "${R}不通${N}（查代理是否放行 api.deepseek.com）\n"
else
  printf "${G}通${N}（HTTP %s）\n" "$HC"
fi

echo "=========================================="
echo "  探测完成。全 ✓ 即可跑 bash install.sh"
echo "=========================================="
