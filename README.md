# claude-code-deploy —— Claude Code + DeepSeek 公司 Mac 一键安装

把 **Claude Code**（Anthropic 官方 CLI）接到 **DeepSeek** 模型，不走 Anthropic 计费。

**原理**：DeepSeek 官方 `/anthropic` 端点原生支持 Anthropic 协议，Claude Code 直连，**不需要任何 proxy / 翻译层**（区别于 [codex-deploy](https://github.com/Beltran12138/codex-deploy) 需要 ccx 翻译 Responses↔Chat）。

## 一行安装（公司 Mac）

终端粘贴回车：

```bash
git clone https://github.com/Beltran12138/claude-code-deploy.git && cd claude-code-deploy && bash install.sh
```

脚本自动：检查 Node → 装 Claude Code → 收 DeepSeek key → 持久化配置 → 自测。
**唯一手动**：粘贴 DeepSeek key。

> **为什么 `git clone` 不是 `curl | bash`**：公司网络 `raw.githubusercontent.com` 不通，但 `github.com` / `git` / `npm` 正常（实测）。

## 前提

- **Node.js 18+**（`node -v` 查；没有找 IT，或 `nvm install 18`）
- **DeepSeek API Key**（platform.deepseek.com 注册，`sk-` 开头）

## 用法

新开终端 → `cd` 到项目目录 → 跑 `claude`。
**不要登录 Anthropic 账号**（直接走 DeepSeek）。首次会过一遍 onboarding（选主题/信任目录），按提示走。

## 换模型

```bash
CLAUDE_MODEL=deepseek-v4-flash bash install.sh   # 重跑覆盖配置，换 flash（更便宜）
```

或直接改 `~/.claude-deepseek-env` 里的 `ANTHROPIC_MODEL`，重开终端。
**1M 上下文**：模型名后加 `[1m]`，如 `deepseek-v4-pro[1m]`。

## 排错

| 报错 | 原因 | 修法 |
|---|---|---|
| `command not found: claude` | npm 全局路径不在 PATH | `npm config get prefix` 看路径，加进 PATH（`export PATH="$(npm config get prefix)/bin:$PATH"`） |
| 自测 `401` / `unauthorized` | DeepSeek key 错或过期 | 重跑 `bash install.sh` 填新 key |
| 自测 `000` | 网络不通 / 代理 | 查公司代理是否放行 `api.deepseek.com` |
| 多轮对话后 `400 thinking mode` | Claude Code + DeepSeek thinking 已知不兼容（[cc-switch#3246](https://github.com/farion1231/cc-switch/issues/3246)） | 重开会话；或改 `~/.claude-deepseek-env` 把 `CLAUDE_CODE_EFFORT_LEVEL=max` 改 `low`/删除后重开终端 |
| 贴图 / 多模态失败 | DeepSeek `/anthropic` 不支持 image / document | 文本任务用，别贴图（[兼容性表](https://api-docs.deepseek.com/guides/anthropic_api/)） |
| 部分 MCP 工具异常 | `mcp_tool_use` block 不支持（普通 `tool_use` 支持） | 待实测，反馈给 IT |

## 卸载

```bash
# 删 zshrc 注入区块
sed -i '' '/# >>> claude-deepseek >>>/,/# <<< claude-deepseek <<</d' ~/.zshrc
rm -f ~/.claude-deepseek-env
npm uninstall -g @anthropic-ai/claude-code   # 可选，删 Claude Code 本体
```

## 安全

- DeepSeek key 只在 `~/.claude-deepseek-env`（权限 600），**不进脚本 / 日志 / 仓库**。
- `~/.zshrc` 只有一行 source 指向 env 文件，**不含 key 明文**。
- 仓库本身不含任何 key。

## 文件

- `install.sh` —— 主安装（装 Claude Code + 配 DeepSeek + 自测）
- `probe.sh` —— 只读环境探测（装机前自检）

## 与 codex-deploy 的区别

| | codex-deploy | claude-code-deploy（本仓库） |
|---|---|---|
| 客户端 | Codex（说 Responses） | Claude Code（说 Anthropic Messages） |
| 翻译层 | **需要 ccx**（Responses↔Chat） | **零翻译层**（DeepSeek 原生 Anthropic 端点） |
| 依赖 | ccx 二进制 + sha256 + launchd 常驻 | 仅 npm 包 + 环境变量 |
| 复杂度 | 高（3 关配置坑） | 低（直连） |
