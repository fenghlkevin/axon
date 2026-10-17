<p align="center">
  <img src="native/Branding/axon-icon.png" width="112" alt="Axon 图标">
</p>

# Axon

**将 SSH、终端、文件管理、主机监控与 AI 编程运维助手放进同一个 macOS 原生工作台。**

Axon 使用 SwiftUI / AppKit 构建，终端基于 SwiftTerm，SSH / SFTP 基于 Citadel。你可以管理服务器、维护文件、查看日志，让 AI 结合当前终端和项目证据持续排查，并在权限控制下完成操作、差异审查和结果验证。

当前源码打包版本：**0.19.29（194）**。运行环境：**Apple Silicon · macOS 15+**。版本以 [打包脚本](native/scripts/package.sh) 为准。

[快速开始](#快速开始) · [全部功能](#全部功能) · [特色功能与截图](#特色功能与截图) · [源码构建](#源码构建) · [使用手册](native/AI-ASSISTANT-MANUAL.md)

## 快速开始

1. 从源码构建 `native/dist/Axon.app`，或使用维护者提供的发行包。构建步骤见下文。
2. 打开应用，在主机库新建 SSH 主机，配置地址、账号和密码、私钥或 SSH Agent；也可以先打开本地终端。
3. 首次连接核对服务器 SHA256 指纹。使用顶部标签切换终端、SFTP 和工作场景。
4. 需要 AI 时，在设置 → AI 助手配置本机 Codex CLI、ChatGPT 兼容 API 或 Claude / CC。先选择「对话助手」熟悉操作，再选择需要执行的本机或 SSH 目标。
5. 帮助 → AI 助手使用手册提供 24 章离线图文指引，包含上下文、权限、项目、文件审查、MCP 和故障恢复。

## 全部功能

### 主机、认证与连接

- 主机网格 / 列表、跨分组搜索、分组、标签、收藏、排序、复制及移动；快速连接支持 `ssh user@hostname -p 2222`。
- 本地共享凭据库：密码、私钥文件或私钥文本；主机引用共享身份，敏感凭据使用 macOS 钥匙串。
- 密码、OpenSSH Ed25519 / RSA 私钥、RSA-SHA2、本机 SSH Agent、跳板机链、断线重连与连接诊断。
- OpenSSH 用户证书、服务器证书与显式信任 CA；首次主机指纹确认、密钥变化拒绝连接及已知主机管理。
- 按主机开启、限定单个身份的 Agent 转发；本地 / 远程 TCP 转发和动态 SOCKS5 TCP 代理（支持远端 DNS）。
- 可配置 tmux 持久会话，断线后重新连接恢复远端屏幕与进程；服务器需具备对应环境。

### 终端与工作场景

- 本地登录 Shell、多个 SSH 标签、最多四终端分屏、拖动合并、独立字号与终端搜索。
- 中文输入、Unicode、复制粘贴、Bracketed Paste、多终端选择性同步键盘与粘贴；同步命令可先填入或确认执行。
- 终端主题、字体、光标、回滚、关键词普通文本 / 正则高亮；高亮按全局、分组或主机设置，不改变原文。
- Bash / Zsh Shell 集成记录目录、命令、耗时和退出状态，支持失败命令筛选、排除规则与长命令完成通知。
- 工作场景保存终端顺序、分屏、初始目录、文件 / 日志路径及转发规则；场景打开为独立工作区。
- 代码片段分组、搜索、排序、参数默认值、类型校验和展开预览；可对多个连接插入或执行。
- 最近打开记录、可调整终端工具侧栏、中英文界面、可配置快捷键与黑 / 白图标。

### SFTP、编辑与传输

- 本地 / 远程、本地 / 本地双栏；路径历史、目录收藏、排序、筛选、隐藏文件、中文名称与多选。
- 上传、下载、本地复制、拖放、递归目录、空文件、进度 / 速度、取消和重试。
- 失败传输重试前校验已传前缀；使用暂存文件提交，覆盖确认，源 / 目标变化检查及失败恢复。
- 创建文件 / 目录、重命名、八进制权限、删除和复制路径；本地删除进废纸篓，远程删除需确认。
- 内置 UTF-8 文本编辑与备份；外部编辑器工作副本、差异审查、冲突检测及确认回传。
- 终端与 SFTP 目录联动、目录精确比较与按固定差异上传；不跟随符号链接传输。

### 监控、日志与批量运维

- Linux CPU、内存、负载、存储、进程、网络 / IP、NVIDIA GPU 及 Docker 只读详情；能力取决于远端环境。
- 主机库监控概览与终端侧栏状态，支持监控分组和分类显示。
- UTF-8 日志跟随、搜索、过滤和导出；终端会话日志手动启停、分页查看、命令定位及导出。
- 命令及日志来源区分 AI、人工、混合和未知，帮助复核实际操作。
- 批量任务按主机 / 分组 / 标签选目标，支持参数模板、并发、超时、实时输出、退出码、取消、失败重试及 JSON 导出。
- 批量任务历史和模板持久化；重试前核对目标身份与路线，异常退出记录明确标为中断。

### 导入、导出与备份

- Tabby YAML、OpenSSH config、Termius 兼容 CSV、PuTTY `.reg` 导入预览、主机去重、分组与跳板关系导入；支持 YAML / CSV / OpenSSH config 导出，具体可迁移字段见 [原生工程说明](native/README.md)。
- 工作区本地保存及备份；加密备份可保存到本地 / iCloud 同步目录及 S3 兼容存储。
- 启动后自动备份、手动立即备份、历史列表与恢复；可保留每次备份或更新固定文件。
- AI 服务配置独立存储，API 密钥放入钥匙串，不随普通工作区导出。

### AI 助手与项目开发

- 本机 Codex CLI、ChatGPT 兼容 Chat Completions API、Claude / CC Messages API；模型、推理强度和速度按后端能力选择。
- 流式回答、停止、追问、失败重试、语音转文字草稿、上下文预览及常见敏感信息脱敏。
- 三种方式：对话助手、当前终端操作、独立执行命令；执行目标绑定到对应会话。
- 读取终端、输入文字、发送按键、等待输出，处理交互程序；后台通道执行诊断并返回真实输出与状态。
- 文件 / 行 / 图片 / 网页引用、项目索引与搜索、多仓库、公开网页检索及来源核对。
- 多会话、持久历史、对话分叉、消息排队、运行中纠正方向、澄清问题和收件箱通知。
- 计划创建、阶段选择、版本比较、提示模板、工作流、知识库、记忆、Skills 与项目指引。
- 多文件修改审查、逐项应用、备份与冲突检查、文件时间线、撤销 / 重做、Git 差异与行评论、worktree。
- 编辑器与语言服务 LSP；Agent 预设、工具权限、运行步数 / 时长限制、Token 用量、费用估算及预算。
- MCP 服务连接、工具选择与调用审批；任务停止、历史恢复、恢复证据及完成验收。
- 每次批准、帮我批准、完整权限三种审批模式；系统 / 主机命令黑白名单及精确操作规则。

## 特色功能与截图

以下为仓库保留的原生 AppKit / SwiftUI 实际界面截图及其操作标注图，使用测试示例数据。截图主要来自 0.19.14–0.19.23，当前版本细节可能略有变化；并非所有功能都有单独截图。[截图来源与生成方式](native/Documentation/ManualScreenshots/README.md)。

### 1. 与终端、项目相连的 AI 对话

结合所选终端、命令和引用材料持续追问，发送前检查上下文；当前终端和独立执行通道按目标隔离。

![AI 对话与上下文](native/Sources/TabbyNative/Resources/AIManual/guide-chat.png)

### 2. 项目索引、文件引用与多仓库

让问题指向具体文件和代码行，在项目范围内搜索并核对依据。

![项目索引与多仓库](native/Sources/TabbyNative/Resources/AIManual/guide-projects.png)

### 3. 计划、阶段与版本比较

将目标拆成计划，在执行前选择阶段，对比计划变化并保留人工控制。

![计划与阶段](native/Sources/TabbyNative/Resources/AIManual/guide-plan.png)

![计划版本比较](native/Sources/TabbyNative/Resources/AIManual/guide-plan-compare.png)

### 4. 文件差异审查与时间线

查看 AI 提议的文件改动，再选择应用；冲突与历史变更有独立入口。

![文件差异审查](native/Sources/TabbyNative/Resources/AIManual/guide-edits.png)

![文件时间线](native/Sources/TabbyNative/Resources/AIManual/guide-timeline.png)

### 5. Git 审查、行评论与 worktree

将开发任务与仓库差异联系起来，在行级讨论修改，并使用独立工作目录。

![Git 行评论](native/Sources/TabbyNative/Resources/AIManual/guide-git-comment.png)

![Worktree](native/Sources/TabbyNative/Resources/AIManual/guide-worktrees.png)

### 6. 知识、模板与 Skills

复用项目背景、知识与流程，检查当前任务实际使用的材料。

![知识与记忆](native/Sources/TabbyNative/Resources/AIManual/guide-knowledge.png)

![Skills 与项目指引](native/Sources/TabbyNative/Resources/AIManual/guide-skills.png)

### 7. 权限明确的工具与 MCP

按任务选择执行方式和审批模式，连接 MCP 服务并审查具体工具调用。

![执行权限](native/Sources/TabbyNative/Resources/AIManual/guide-permissions.png)

![MCP 工具审批](native/Sources/TabbyNative/Resources/AIManual/guide-mcp-approval.png)

### 8. 用量预算与失败恢复

查看模型用量和预算，停止或恢复任务时核对证据，避免把文件写入误当作服务已经恢复。

![用量与预算](native/Sources/TabbyNative/Resources/AIManual/guide-usage.png)

![任务恢复与验收](native/Sources/TabbyNative/Resources/AIManual/guide-recovery.png)

### 9. 内置离线图文手册

24 章涵盖首次配置到开发、运维与恢复，支持搜索、图片放大和示例复制。

![离线图文手册](native/Documentation/ManualScreenshots/ui-0.19.21-start-1060.png)

## 数据与能力边界

- 配置位于 `~/Library/Application Support/TabbyNative/`，主工作区为 `workspace.json`；密码、私钥口令、私钥文本和 API Key 使用 macOS 钥匙串。
- AI 请求会将所选上下文发送给已配置服务。自动脱敏不能替代发送前检查；会话输出日志默认关闭，开启后可能包含终端回显的敏感内容。
- 当前终端模式共享正在运行的 Shell / REPL；独立执行模式不继承交互 Shell 的别名、虚拟环境和后续目录变化。停止任务不会自动撤销已完成修改。
- 命令正则规则不是操作系统沙箱；远端认证、权限及工具可用性仍决定执行结果。
- 持久会话需要服务端 tmux 3.3+ 和 Bash；批量超时需要 `timeout` / `gtimeout`。监控主要面向 Linux。
- 尚不提供云端团队协作、移动端、mosh、PKCS#11、键盘交互认证和 ProxyCommand。原生版与 Tabby Electron 的功能集合不同。
- 当前打包流程支持本机签名或 ad-hoc 签名；公开分发的 Developer ID 公证需另行完成。

## 源码构建

原生工程在 `native/`，依赖由 Swift Package Manager 管理，解析版本保存在 `Package.resolved`，Citadel / NIOSSH 补丁见 [Vendor 说明](native/Vendor/README.md)。使用具备兼容 Swift 工具链的 Xcode，在仓库根目录运行：

```sh
git clone https://github.com/fenghlkevin/tabby.git
cd tabby
git checkout main
swift build --package-path native
swift test --package-path native
native/scripts/package.sh release
open native/dist/Axon.app
```

产物为 `native/dist/Axon.app` 和 `native/dist/Axon-0.19.29-mac-arm64.zip`。打包脚本执行签名校验；可使用 `AXON_SIGN_IDENTITY` 指定签名身份。生成产物不作为源码提交。

SSH / SFTP 集成测试需要临时本地测试服务器；未配置时相关测试会跳过。设置步骤和覆盖范围见 [原生工程开发说明](native/README.md#集成测试)。UI 和交付检查记录见 [VERIFICATION.md](native/VERIFICATION.md)。

## 仓库导航

| 路径 | 内容 |
| --- | --- |
| `native/Sources/TabbyNative/` | Axon 原生应用源码 |
| `native/Tests/` | 单元、集成及原生界面测试 |
| `native/Sources/TabbyNative/Resources/AIManual/` | 随应用离线打包的手册与配图 |
| `native/AI-ASSISTANT-MANUAL.md` | 24 章 AI 操作手册 |
| `native/scripts/` | 打包、测试服务器及手册资源生成脚本 |
| `native/Vendor/` | 固定版本依赖补丁与许可证说明 |
| `app/`、`tabby-*` | 保留的 Tabby Web / Electron 工程 |

本仓库同时保留上游 Tabby Web / Electron 源码；其介绍与开发入口见 [Tabby 原始 README](README.tabby.md)，其他语言的 `README.*.md` 仍为上游文档。

## 开源许可

仓库基于 MIT 许可证，详见 [LICENSE](LICENSE)。SwiftTerm、Citadel、Yams 及其他第三方依赖的许可由打包流程汇总到应用内 `ThirdPartyNotices`；修改过的依赖另见 [Vendor/README.md](native/Vendor/README.md)。
