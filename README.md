# 提示词助手

一个独立的 macOS 小窗工具：选中一段 Codex 聊天，把「帮我优化一下」这样的想法变成可直接使用的增强版提示词。也可以点「推荐下一步」，根据所选聊天生成建议。

## 下载与运行

1. 从 [GitHub Releases](https://github.com/renzhihe110/CodexPromptAssistant/releases/latest) 下载 macOS Universal ZIP，解压后将其中的应用拖到「应用程序」。支持 macOS 14 或更高版本，适用于 Apple 芯片及 Intel Mac。
2. 本机需安装并登录 Codex，提示词助手通过本机 Codex CLI 的 App Server 工作；可使用 Codex 桌面应用内置的 CLI。生成需要可用的模型访问权限。
3. 此版使用 ad hoc 临时签名，未通过 Apple 公证。macOS 首次打开可能提示无法验证开发者。如果不希望运行未经公证的下载，可按下方步骤从源码构建。

启动时会检查此仓库的最新正式版，也可从菜单栏的提示词助手图标选择「检查更新」。点击「更新」后，应用会下载安装包，核对 SHA-256、架构、签名及 Gatekeeper 结果。若有未保存的轮次，可以取消并先复制内容；继续后会替换当前应用并重启，沿用原有配置。更新需要安装目录可写，且发布的安装包须通过当前 Mac 的安全校验。

## 使用

- 选择来源聊天，输入需求、添加参考图，或直接点「推荐下一步」。
- 输入自己的想法后，先得到可编辑、可复制的增强版。必要的缺失事实用「[待补充：具体信息]」标明。下方一次列出当前关键问题。选答、自填和补充都先暂存，点「更新增强提示词」才会按最近编辑的正文更新，并刷新剩余问题。没有待澄清事项时可直接复制。
- 「推荐下一步」沿用逐题澄清与候选方案流程，可点「结束提问，生成提示词」。
- 在「+」菜单选择「筛选快照」或「侧边聊天」上下文模式。生成使用本机 Codex 的模型服务，来源内容和本次附图可能作为模型输入。
- 在候选旁编辑、复制，或点击「发送到 Codex」。直接发送需要 Codex 桌面版和 macOS 辅助功能权限，并会覆盖目标输入框中未发送的草稿。
- 提示词助手窗口有焦点时，按 ⌘D 可在完整窗口与紧凑输入栏之间切换。

## 从源码构建

安装兼容的 Xcode 后，可以打开 CodexPromptAssistant.xcodeproj，选择 CodexPromptAssistant 和 My Mac 运行；也可在项目根目录执行：

```sh
xcodebuild -project CodexPromptAssistant.xcodeproj -scheme CodexPromptAssistant \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build
```

产物位于 `build/Build/Products/Release/提示词助手.app`。工程及其资源已包含在仓库中，无需安装第三方 Swift 包或重新生成工程。
