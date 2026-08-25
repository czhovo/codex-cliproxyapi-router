# Codex CLIProxyAPI Router for Windows

一个面向 Codex App 的本机双层路由工具：在同一个模型选择器中动态合并 GPT 与
DeepSeek，并允许在两种 GPT 认证路径之间切换。所有本地服务只监听
`127.0.0.1`，仓库不包含 API key、OAuth 文件、运行日志或 CLIProxyAPI 二进制。

> 本项目是非官方的本地集成。使用者需要自行遵守 OpenAI、DeepSeek、CLIProxyAPI
> 以及 Codex App 的适用条款。不要把订阅登录凭据或 API key 分享给他人。

## 路由拓扑

```text
Codex App (built-in provider: openai)
  openai_base_url = http://127.0.0.1:8318/v1
                       |
                       +-- GET /v1/models ------> 8317 catalog + local transforms
                       |
                       +-- GPT, mode 1 ----------> official Codex Responses endpoint
                       |                           (native Codex App credentials)
                       |
                       +-- GPT, mode 2 ----------> 8317 CLIProxyAPI
                       |                           (independent Codex OAuth)
                       |
                       +-- DeepSeek/other --------> 8317 CLIProxyAPI
                                                   -> https://api.deepseek.com
```

- `8318`：Node.js 兼容层，处理模型目录、路由、模型别名、压缩请求和 Responses SSE。
- `8317`：官方 CLIProxyAPI `v7.2.119`，处理 DeepSeek API key 与可选的独立 Codex OAuth。
- WebSocket Upgrade 返回 `426`，Codex 使用 HTTP Responses 流。

## 两种 GPT 模式

### Mode 1：GPT 官方直连

满足以下条件的 `gpt-*` Responses 请求由 8318 直接转发到官方 Codex Responses
端点：请求同时携带 Codex App 原生 `Authorization` 与 `chatgpt-account-id`。
所需认证头和原始请求体会被保留，GPT 不进入 8317。若缺少原生凭据，8318 返回明确
的 `401`，不会静默回退到独立 OAuth。

DeepSeek 和其他代理模型仍走 8318 → 8317。

### Mode 2：GPT 使用独立 OAuth

GPT、DeepSeek 和其他代理模型全部走 8318 → 8317。GPT 使用 CLIProxyAPI `auth/`
目录中的独立 Codex OAuth。首次启用 Mode 2 且缺少该凭据时，启用脚本会启动浏览器
登录流程。

模式写入本机 `routing-mode.txt` 并由开机启动流程保留；`/health` 会报告当前模式。

## 模型目录行为

目录由当前上游模型动态生成，不要求任何固定模型必须存在：

- 上游存在 `gpt-5.6-sol` 时，发布两个选择项：
  - `gpt-5.6-sol` → `GPT 5.6 Sol · 272k`
  - `gpt-5.6-sol-1m` → `GPT 5.6 Sol · 1.05M`
- `gpt-5.6-sol-1m` 只是本地目录别名；发送到官方或 8317 前会改写为
  `gpt-5.6-sol`。它不会改变账号本身的模型权限。
- 两个 Sol 项保留 GPT 的 `max` / `ultra` 推理强度与 Fast / `priority`，默认速度为
  Fast。
- 隐藏模型选择器中的 `gpt-5.5`、`gpt-5.4`、`gpt-5.4-mini`。
- 上游存在 `deepseek-v4-flash` 或 `deepseek-v4-pro` 时才发布对应项；二者均为
  1M context、`low / high / max`、默认 `high`，且不声明 Fast / service tier。

## 稳定性与安全处理

- 支持 `identity`、`gzip`、`zstd`、`deflate`、`br` 请求体识别；路由后仍转发原始
  压缩字节与原始 `content-encoding`。
- GPT 官方 HTTPS 与本地 8317 HTTP 使用受控 keep-alive Agent。
- 仅对“复用连接、响应头到达前的 `ECONNRESET`”进行一次内部重试；当前版本还对
  TLS 握手前的短暂 reset 使用两个有界退避（250 ms、750 ms）。不会任意重试已经
  开始执行的长 POST。
- 同时识别 `event: response.completed` 与 JSON `"type":"response.completed"`；
  完成后客户端关闭不会误记为失败。
- 请求上限 64 MiB，错误体采集上限 2 MiB；非 2xx 响应原样返回。
- 日志只记录有界、结构化、脱敏后的错误字段，不记录 prompt、OAuth、API key、
  Cookie 或完整账户 ID。
- 启用前执行 Node.js 语法检查；启用失败时回滚 Codex 配置、目录、模式、启动项与本次
  新启动的服务。
- 凭据 ACL 只允许当前用户、`SYSTEM` 与本机 Administrators。

## 系统要求

- Windows 10/11 x64
- 已安装并登录的 Codex App
- Windows PowerShell 5.1 或 PowerShell 7
- Node.js（`node.exe` 可从 `PATH` 找到）
- DeepSeek API key
- Mode 2 额外需要可完成 CLIProxyAPI Codex OAuth 登录

Codex 配置字段的官方说明见
[Codex config reference](https://learn.chatgpt.com/docs/config-file/config-reference)。

## 安装

克隆仓库并运行安装器：

```powershell
git clone https://github.com/czhovo/codex-cliproxyapi-router.git
Set-Location .\codex-cliproxyapi-router
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Install-CLIProxyAPIRouter.ps1
```

安装器会：

1. 从 CLIProxyAPI 官方 GitHub Release 下载固定的 `v7.2.119` Windows x64 包；
2. 核对官方 SHA-256
   `1518a0ffc4f89b609c091f9302c9e3045cffa27e32a4c49f9d211f051de78688`；
3. 把通用脚本安装到当前用户的 Codex 数据目录；
4. 生成随机本地代理 key，创建空的 DeepSeek key 文件并保护 ACL；
5. 默认在当前用户桌面安装 `enable-cliproxy.cmd` 与 `reset-codex.cmd`。

安装器**不会**启动服务、修改 `config.toml` 或重启 Codex App。
如已自行下载同一官方 ZIP，可用 `-ArchivePath <zip>` 离线安装；文件仍必须通过相同的
固定 SHA-256 校验。

随后用文本编辑器打开安装器创建的 DeepSeek key 文件，并只粘贴 key 本身：

```powershell
$keyPath = Join-Path $env:USERPROFILE '.codex\deepseek_api_key.txt'
notepad.exe $keyPath
```

保存后重新应用凭据 ACL：

```powershell
$protector = Join-Path $env:USERPROFILE '.codex\tools\cliproxyapi\Protect-CLIProxyAPICredentials.ps1'
& $protector
```

不要在命令行参数、Git 配置、README、Issue 或日志中粘贴 key。

## 启用

双击桌面的 `enable-cliproxy.cmd` 会交互询问 Mode 1 或 Mode 2，然后启动 8317/8318、
生成动态目录、写入 Codex 配置、安装当前用户的 Windows 登录启动项，并默认安排 Codex
App 重启。

如果不希望脚本重启 Codex App，显式使用 `-NoRestart`：

```powershell
$enable = Join-Path $env:USERPROFILE '.codex\Enable-CLIProxyAPI.ps1'
& $enable -Mode 1 -NoRestart
# 或：& $enable -Mode 2 -NoRestart
```

`-NoRestart` 下配置会立即落盘，但已打开的 Codex App 通常要在之后手动重启才能刷新
模型目录。

启用后的核心 Codex 设置为：

```toml
model_provider = "openai"
openai_base_url = "http://127.0.0.1:8318/v1"
model_catalog_json = "<current-user Codex data>/cliproxy-model-catalog.json"
service_tier = "priority"
```

## 回退到官方直连

双击桌面的 `reset-codex.cmd`，或无重启执行：

```powershell
$reset = Join-Path $env:USERPROFILE '.codex\Restore-GPT56Sol-ChatGPT.ps1'
& $reset -NoRestart
```

Reset 会：

- 删除 `openai_base_url` 与 `model_catalog_json` 覆盖；
- 恢复内置 `openai` provider、`gpt-5.6-sol`、`xhigh`、Fast / `priority`；
- 删除本地模型目录与持久化路由模式；
- 删除 CLIProxyAPI 登录启动项；
- 停止 8318 与 8317（除非显式使用脚本的 `-KeepProxyRunning`）。

它不会删除 DeepSeek API key或 OAuth 凭据。

## 验证

```powershell
Invoke-RestMethod -Uri http://127.0.0.1:8318/health
Get-NetTCPConnection -State Listen -LocalAddress 127.0.0.1 -LocalPort 8317,8318

$catalogPath = Join-Path $env:USERPROFILE '.codex\cliproxy-model-catalog.json'
(Get-Content -Raw -Encoding UTF8 $catalogPath | ConvertFrom-Json).models |
    Select-Object slug, display_name, context_window, default_service_tier
```

仓库自身的离线检查不会启动或停止服务：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Package.ps1
```

## 文件说明

| 文件 | 用途 |
|---|---|
| `src/codex-catalog-compat.mjs` | 8318 路由、目录合并、SSE/压缩/错误处理 |
| `config/config.template.yaml` | 无凭据的 8317 配置模板 |
| `scripts/Install-CLIProxyAPIRouter.ps1` | 下载并校验 CLIProxyAPI、安装通用文件 |
| `scripts/Enable-CLIProxyAPI.ps1` | 事务式启用 Mode 1/2 与动态目录 |
| `scripts/Restore-GPT56Sol-ChatGPT.ps1` | 恢复 Codex 官方直连 |
| `scripts/Start-CLIProxyAPI.ps1` | 防重复、带健康检查地启动/重载 8317/8318 |
| `scripts/Stop-CLIProxyAPI.ps1` | 只停止属于本工具的进程 |
| `scripts/New-RuntimeConfig.ps1` | 从占位符模板生成含凭据的运行配置 |
| `scripts/Protect-CLIProxyAPICredentials.ps1` | 应用并验证 Windows 凭据 ACL |
| `scripts/Update-CodexModelCatalog.ps1` | 获取并验证动态模型目录 |
| `scripts/Login-CodexOAuth.ps1` | Mode 2 独立 Codex OAuth 登录 |
| `scripts/Restart-CodexApp.ps1` | 独立 worker 安排 Codex App 重启 |
| `startup/CLIProxyAPI-Autostart.vbs` | Windows 登录时仅启动本地服务，不改模式 |
| `launchers/*.cmd` | 桌面双击入口与临时错误日志清理 |

## 不会被提交的内容

`.gitignore` 和离线测试共同排除并检查：API key、OAuth `auth/`、本地 client key、
`config.runtime.yaml`、日志、PID、模式文件、生成目录、二进制、ZIP 与备份。提交或分享
日志前仍应人工复查并删除可能关联个人环境的元数据。
