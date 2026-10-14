# 手册操作图来源

这里保存用于 0.19.23 手册的原生 AppKit / NSHostingView 界面截图。图片来自已验收的本机测试夹具，路径、命令、问答和服务均为示例；没有读取用户服务器。`ui-0.19.*` 文件保留原验收版本；`axon-current-*` 和 `axon-manual-ui-*` 来自当前 `AIManualTests.testCaptureManualEntryPoints`，用于补全或更新服务、权限、执行方式和运行中协作入口。

`native/scripts/manual-illustrations.json` 定义章节归属、源图、裁切区域、三个编号的位置及对应使用说明。编号坐标相对裁切后的真实截图。新配图应检查真实控件及已连接／未连接、可用／禁用状态，不把概念草图当作产品截图。

从仓库根目录重新生成操作图和文字参考：

```sh
swift native/scripts/render-manual-illustrations.swift
python3 native/scripts/sync-manual-content.py
```

生成图保存到 `native/Sources/TabbyNative/Resources/AIManual/`，随 SwiftPM 资源离线打包。每章至少一张；复杂章节有多张，每张独立标题和说明，可单独放大。重新生成后必须打开图片检查编号、裁切与文字，并运行 `AIManualTests` 验证全部图片资源和多图交互。

`axon-01923-*` 来自 AIOptimizationTests 的实际原生界面，用于收件箱搜索、未读处理和对话重试说明。
