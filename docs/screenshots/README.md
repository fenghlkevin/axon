# README 全景截图

2026-10-17 从 Axon 0.19.29 当前源码，通过临时 NSHostingView / MainView 渲染夹具生成。使用真实 SwiftUI、AppKit、SwiftTerm 控件，没有拼接界面或生成式图片。

- `axon-hosts.png`：1440 × 960 pt，主机库列表、分组、标签和完整导航。
- `axon-terminal-ai.png`：1440 × 960 pt，原生终端与 AI 工具面板。
- `axon-files.png`：1440 × 960 pt，本地 / 本地双栏文件管理。
- `axon-batch.png`：1440 × 1400 pt，完整批量任务工作区，包含目标、命令、结果与输出。

PNG 为 2× 像素密度。所有主机使用文档示例地址 192.0.2.0/24；终端输出、AI 回答、任务结果均由隔离夹具提供，文件来自 `/tmp/axon-readme-demo/` 示例目录。未连接用户服务器，未向外部 AI 服务发送请求，也未执行图中的命令。截图用于展示界面，不是运行状态或服务健康的证据。

截图夹具 `ReadmeCaptureTests.testCapturePanoramas` 运行通过，0 失败；输出位于 `/tmp/axon-readme-panoramas/`，临时夹具完成后已移除。四张截图均已打开检查，调整过 AI 回答长度与批量页面窗口高度，确认主要内容及结果完整可见。
