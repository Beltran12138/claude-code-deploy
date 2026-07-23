#!/usr/bin/env bash
# ============================================================
# Claude Code + BitV 一键安装（公司 Mac）—— v2 无 CCR
# 路径：claude → proxy(:8423 /v1/messages 自翻译 Anthropic→Chat) → BitV 网关
#
# v1 用 CCR 做翻译层，实测坑深（gateway key 每次重启重生 / apiKeyHelper 全局劫持
# settings.json / 4 端口地狱 / billing SQLite 覆盖），非技术同事无法复现调试。
# v2 砍掉 CCR：翻译逻辑内置进 proxy.js（tools/SSE 全覆盖，mock 28/28 验过），
# 单层、确定性、一台通台台通。
#
# 与个人 DeepSeek 场景隔离：不碰 ~/.zshrc、不劫持全局 settings.json；
# 配置进 ~/.claude-bitv-env（600），由 ~/bin/claude-bitv 显式 source。
# 若机器上有 v1 遗留的 CCR 劫持，会自动清理（备份后）。
# 用法： bash install-bitv.sh   （幂等）
# 前置：Node 18+ / npm / curl；BitV key（向何总申请，sk- 开头）；公司 VPN（BitV 内网）
# ============================================================
set -uo pipefail

PROXY_PORT=8423
PROXY_DIR="$HOME/chat-path-rewrite-proxy"
PROXY_RAW="https://raw.githubusercontent.com/Beltran12138/chat-path-rewrite-proxy/main"
ENV_FILE="$HOME/.claude-bitv-env"
LAUNCHER="$HOME/bin/claude-bitv"
SETTINGS="$HOME/.claude/settings.json"
CCR_PLIST="$HOME/Library/LaunchAgents/com.local.ccr.plist"
DUMMY_TOKEN="bitv-proxy-local"   # 占位：proxy 忽略客户端 token、注入真 BitV key

G='\033[32m'; Y='\033[33m'; R='\033[31m'; N='\033[0m'
ok(){ printf "${G}✓${N} %s\n" "$1"; }
info(){ printf "  %s\n" "$1"; }
warn(){ printf "${Y}!${N} %s\n" "$1"; }
die(){ printf "${R}✗ %s${N}\n" "$1" >&2; exit 1; }

# 健壮拉取：重试 + 完整性哨兵（防 raw 间歇性半截下载→跑损坏脚本）
fetch(){
  local url="$1" dest="$2" mode="${3:-sentinel}" a
  for a in 1 2 3 4 5; do
    if curl -fsSL --retry 3 --retry-all-errors --retry-delay 2 --connect-timeout 15 --max-time 120 "$url" > "$dest.part" 2>/dev/null; then
      if [ "$mode" = json ]; then
        [ -s "$dest.part" ] && tail -c 5 "$dest.part" | grep -q '}' && { mv "$dest.part" "$dest"; return 0; }
      else
        grep -q '__FETCH_OK__' "$dest.part" && { mv "$dest.part" "$dest"; return 0; }
      fi
    fi
    warn "拉取 $(basename "$dest") 第 $a 次不完整/超时，重试..."; sleep 2
  done
  rm -f "$dest.part"; die "拉取 $url 失败（重试 5 次仍不完整——raw 间歇性差，稍后重跑本命令）"
}

echo "=========================================="
echo "  Claude Code + BitV 一键安装（v2 无 CCR）"
echo "=========================================="

# ---- 0. 前置 ----
echo "【0/6】检查环境..."
command -v node >/dev/null || die "缺 Node.js（装 Node 18+：nvm install --lts）"
NM="$(node -v | sed 's/v//;s/\..*//')"
[ "$NM" -ge 18 ] 2>/dev/null || die "Node 版本过低（$(node -v)），需 18+"
command -v npm  >/dev/null || die "缺 npm"
command -v curl >/dev/null || die "缺 curl"
ok "Node $(node -v) / npm $(npm -v)"

# ---- 1. 清理 v1 遗留的 CCR 劫持（若有）----
echo "【1/6】清理旧 CCR 残留（v1 遗留，若无则跳过）..."
if [ -f "$CCR_PLIST" ]; then
  launchctl bootout "gui/$(id -u)/com.local.ccr" 2>/dev/null || launchctl unload "$CCR_PLIST" 2>/dev/null || true
  mv "$CCR_PLIST" "${CCR_PLIST}.disabled-by-bitv" 2>/dev/null || true
  warn "已停用旧 CCR 开机自启（备份为 com.local.ccr.plist.disabled-by-bitv）"
fi
# 清 settings.json 里 CCR 注入的 apiKeyHelper / env.ANTHROPIC_BASE_URL（会和我们的 env 打架）
if [ -f "$SETTINGS" ] && command -v python3 >/dev/null; then
  CLEAN="$(python3 - "$SETTINGS" <<'PY'
import json,os,sys,shutil
p=sys.argv[1]
try: d=json.load(open(p,encoding='utf-8'))
except Exception: sys.exit(0)
changed=False
h=d.get('apiKeyHelper')
if isinstance(h,str) and ('claude-code-router' in h or '/ccr' in h or 'ccr-' in h):
    d.pop('apiKeyHelper',None); changed=True
env=d.get('env')
if isinstance(env,dict):
    bu=env.get('ANTHROPIC_BASE_URL','')
    if isinstance(bu,str) and any(x in bu for x in (':3455',':3456',':3457',':3458',':3459')):
        env.pop('ANTHROPIC_BASE_URL',None); changed=True
    for k in ('ANTHROPIC_API_KEY','ANTHROPIC_AUTH_TOKEN'):
        v=env.get(k,'')
        if isinstance(v,str) and v.startswith('ccr-'): env.pop(k,None); changed=True
    if not env: d.pop('env',None)
if changed:
    shutil.copy(p,p+'.pre-bitv.bak')
    json.dump(d,open(p,'w',encoding='utf-8'),indent=2,ensure_ascii=False)
    print('cleaned')
PY
)"
  [ "$CLEAN" = cleaned ] && warn "已从 ~/.claude/settings.json 移除 CCR 劫持（备份 .pre-bitv.bak，恢复了个人场景的 claude）"
fi
ok "CCR 残留清理完成"

# ---- 2. 装/升级 Claude Code ----
echo "【2/6】安装 Claude Code..."
npm install -g @anthropic-ai/claude-code >/dev/null 2>&1 || die "npm 装 claude-code 失败（查网络/npm registry）"
ok "Claude Code $(claude --version 2>/dev/null || echo '已装')"

# ---- 3. 确保 proxy 在跑（:8423；带 Anthropic 翻译的新版）----
echo "【3/6】确保 proxy 在跑（:${PROXY_PORT}，带 /v1/messages 翻译）..."
# 强制重装：v1 机器上的旧 proxy.js 是纯 path-rewrite，不会翻译 /v1/messages，必须换成新版
mkdir -p "$PROXY_DIR"
fetch "$PROXY_RAW/install-proxy.sh" "$PROXY_DIR/install-proxy.sh" sentinel
fetch "$PROXY_RAW/proxy.js"         "$PROXY_DIR/proxy.js"         sentinel
fetch "$PROXY_RAW/package.json"     "$PROXY_DIR/package.json"     json
info "proxy 文件已就位（最新版，完整性已校验）"
if curl -fsS -m 3 "http://localhost:${PROXY_PORT}/v1/models" >/dev/null 2>&1; then
  info "proxy 已在线——重启以加载新版 proxy.js（含翻译层）"
  launchctl kickstart -k "gui/$(id -u)/com.bitv.proxy" 2>/dev/null || bash "$PROXY_DIR/install-proxy.sh" || die "proxy 重装失败"
else
  warn "proxy 未跑，开始装（会让你粘 BitV key）..."
  bash "$PROXY_DIR/install-proxy.sh" || die "proxy 安装失败，见上方输出"
fi
sleep 2
curl -fsS -m 5 "http://localhost:${PROXY_PORT}/v1/models" >/dev/null 2>&1 && ok "proxy 在线（:${PROXY_PORT}）" || warn "proxy 端口暂未响应，稍后自测再看"

# ---- 4. 写 ~/.claude-bitv-env（隔离，不进 zshrc）----
echo "【4/6】写隔离环境 ${ENV_FILE}..."
umask 077
cat > "$ENV_FILE" <<EOF
# Claude Code -> BitV（install-bitv.sh v2 生成；权限 600）
# 不进 ~/.zshrc、不碰全局 settings.json —— 由 ~/bin/claude-bitv 显式 source，与个人 DeepSeek 场景隔离
# 先清掉可能从父 shell / DeepSeek 场景漏进来的冲突变量
unset ANTHROPIC_API_KEY ANTHROPIC_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL CLAUDE_CODE_SUBAGENT_MODEL 2>/dev/null || true
# 指向本地 proxy；token 是占位（proxy 忽略它、注入真 BitV key），非空即可免登录
export ANTHROPIC_BASE_URL="http://127.0.0.1:${PROXY_PORT}"
export ANTHROPIC_AUTH_TOKEN="${DUMMY_TOKEN}"
EOF
chmod 600 "$ENV_FILE"
ok "环境已写（权限 600）"

# ---- 5. 写 launcher claude-bitv ----
echo "【5/6】写启动器 ${LAUNCHER}..."
mkdir -p "$(dirname "$LAUNCHER")"
cat > "$LAUNCHER" <<'EOF'
#!/usr/bin/env bash
# BitV 场景启动器：source 隔离 env + 启 claude（个人场景仍用原生 claude）
[ -f "$HOME/.claude-bitv-env" ] && . "$HOME/.claude-bitv-env" \
  || { echo "❌ 找不到 ~/.claude-bitv-env，先跑 install-bitv.sh" >&2; exit 1; }
exec claude "$@"
EOF
chmod +x "$LAUNCHER"
ok "启动器已装：$LAUNCHER"
case ":$PATH:" in *":$(dirname "$LAUNCHER"):"*) : ;; *) warn "$(dirname "$LAUNCHER") 不在 PATH——用全路径调 $LAUNCHER，或加进 ~/.zshrc: export PATH=\"\$HOME/bin:\$PATH\"" ;; esac

# ---- 6. 自测（真发一条 Anthropic /v1/messages，走完整翻译链）----
echo "【6/6】自测（Claude 协议 /v1/messages → 翻译 → BitV）..."
TF="$(mktemp)"
CODE="$(curl -s -o "$TF" -w '%{http_code}' --max-time 90 \
  "http://127.0.0.1:${PROXY_PORT}/v1/messages" \
  -H 'content-type: application/json' \
  -H 'anthropic-version: 2023-06-01' \
  -H "x-api-key: ${DUMMY_TOKEN}" \
  -d '{"model":"claude-sonnet-4-5","max_tokens":50,"messages":[{"role":"user","content":"Reply with exactly: OK"}]}' 2>/dev/null || echo 000)"
echo
if [ "$CODE" = "200" ] && grep -q '"type":"message"' "$TF" 2>/dev/null; then
  ok "✅ BitV 经 proxy 翻译打通（HTTP 200，Anthropic 回译正常）"
  info "回包：$(head -c 160 "$TF")"
else
  warn "自测 HTTP=${CODE}（未拿到 Anthropic 回包）——不阻塞安装，多半是下面几种："
  info "1. 没连公司 VPN → BitV 上游(内网 30.100.0.3)不通；连 VPN 后自然可用"
  info "2. glm4.7 冷启动 30-60s → 稍等重试"
  info "3. BitV key 无效/过期 → 找何总；或 proxy 没起：tail -50 $PROXY_DIR/proxy.err.log"
  info "响应：$(head -c 200 "$TF")"
fi
rm -f "$TF"

cat <<EOF

${G}========================================================${N}
 完成！新开终端，cd 到项目目录，跑：
   ${Y}claude-bitv${N}
 ${Y}不要登录 Anthropic 账号${N}（直接走 BitV，glm4.7）。
 首次会过 onboarding（选主题/信任目录），按提示走。
 与个人 DeepSeek 场景互不冲突：个人用 ${Y}claude${N}，公司 BitV 用 ${Y}claude-bitv${N}。
 无 CCR、无 Web UI、无手动步——proxy 内置翻译，重启自愈。
${G}========================================================${N}
EOF

# __CLAUDE_BITV_OK__
