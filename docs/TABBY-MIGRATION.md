# Tabby 归档与 Axon 迁移

自 2026-10-17 起，主分支仅维护 `native/` 下的 Axon。

## 旧工程归档

- 分支：`archive/tabby-legacy-2026-10-17`
- 归档提交：`1a6a6792bfc318f59ea637a816e56390946d01c6`
- 归档包含清理前所有 Git 跟踪文件及完整历史：Tabby Web / Electron 源码、插件、构建与 CI 配置、多语言文档、许可证和当时的 Axon 源码。
- `node_modules/`、`builtin-plugins/`、根目录 `dist/` 等未跟踪的生成物不属于 Git 归档，已从本机旧工程目录清理；旧工程依赖仍由归档中的清单和锁文件描述。
- 归档用于历史查询，不再维护原 Tabby 的功能、依赖和发行流程。

无需切换工作区即可查阅旧资料：

```sh
git show archive/tabby-legacy-2026-10-17:README.tabby.md
git show archive/tabby-legacy-2026-10-17:HACKING.md
git ls-tree --name-only archive/tabby-legacy-2026-10-17
```

主分支已移除旧应用、插件、翻译、Node 清单和锁文件、Webpack / Electron 配置、Windows / Linux 打包资源，以及原 Tabby 的构建、文档发布、发行和 JavaScript 扫描工作流。没有新增 Axon CI；原生构建入口继续为 `native/Package.swift` 和 `native/scripts/package.sh`。

## 将主机配置迁移到 Axon

1. 保留一份原 Tabby 配置文件备份（通常为 `config.yaml`），不要覆盖原文件。
2. 在 Axon 中打开「设置 → 导入与导出」，选择「Tabby YAML」。
3. 选择配置文件，检查预览与警告后导入。按地址、端口和有效用户名匹配重复主机。
4. 检查主机地址、账号、端口、分组、私钥路径和跳板关系，首次连接核对主机指纹。私钥文件需在当前电脑上可访问。
5. 加密保险库、SSH Agent 配置、代理命令、端口转发和登录脚本不自动迁移；在 Axon 中重新配置所需项目。原 Electron 插件、界面设置和 xterm 渲染配置也不能直接复用。

Axon 使用独立的 `~/Library/Application Support/TabbyNative/workspace.json`；凭据由 macOS 钥匙串管理。导入导出实现与相关测试仍保留在 `native/`，参见 [原生工程说明](../native/README.md)。不要直接把旧 Tabby 配置替换为 Axon 工作区文件。

## 许可证与来源

根目录 [LICENSE](../LICENSE) 原样保留 Tabby Developers 的 MIT 版权和许可声明。[行为准则](../CODE_OF_CONDUCT.md) 继续保留。已移除旧依赖的许可文件随对应源码保留在归档分支中。

Axon 仍使用的第三方依赖及补丁许可保留在 `native/`；详见 [Vendor 说明](../native/Vendor/README.md)。原生打包脚本仍从根目录 LICENSE 生成 `ThirdPartyNotices/Tabby-LICENSE`，不应删除或改写该声明。
