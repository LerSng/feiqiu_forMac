# 飞秋 Mac
<div align="center">
  <img src="app.xcassets/AppIcon.appiconset/icon_256x256.png" width="96" alt="飞秋 Mac 图标">
  <h3>原生 macOS 局域网即时通讯客户端</h3>
  <p>连接飞秋 / IP Messenger 用户，在 Mac 上收发消息、图片和文件。</p>

  <p>
    <img src="https://img.shields.io/badge/macOS-14.0%2B-111111?logo=apple&logoColor=white" alt="macOS 14.0+">
    <img src="https://img.shields.io/badge/Swift-5-F05138?logo=swift&logoColor=white" alt="Swift 5">
    <img src="https://img.shields.io/badge/SQLite-local-003B57?logo=sqlite&logoColor=white" alt="SQLite">
    <img src="https://img.shields.io/badge/UDP%2FTCP-2425-2F80ED" alt="UDP/TCP 2425">
  </p>
</div>

> 当前版本：<code>0.1.1</code>（Build <code>2</code>）
>
> 飞秋 Mac 是独立的第三方项目，不隶属于飞秋或其相关商业主体。应用面向可信 IPv4 局域网，不提供端到端加密，也不依赖中心服务器。

## ✨ 功能概览

| 模块 | 能力 |
| --- | --- |
| 局域网通信 | 用户发现、在线状态、文字消息、回执、输入状态、抖一抖和飞秋表情 |
| 图片与文件 | 内嵌图片、普通文件、剪贴板图片、系统截屏、拖拽直发、缩略图与预览 |
| 聊天体验 | SwiftUI 原生界面、分页历史、未读数、联系人搜索、图片图库和文件 Quick Look |
| 历史管理 | SQLite 持久化、按会话 / 日期 / 关键词 / 类型组合搜索，一键定位原消息 |
| 记录归档 | TXT、Markdown、HTML 导出；支持导入本应用的完整导出记录及附件 |
| 会话管理 | 置顶、免打扰、备注、标签、屏蔽和独立的提醒策略 |
| 下载中心 | 收发任务、历史附件、进度、并发控制、队列暂停、取消和失败重试 |
| 本地维护 | IP 变化后的联系人延续、数据库占用统计、附件清理、备份与恢复 |

## 🚀 快速开始

### 环境要求

- macOS <code>14.0+</code>
- Xcode <code>15+</code>
- Mac 与飞秋 / IP Messenger 客户端处于可互通的 IPv4 局域网
- 防火墙允许 UDP/TCP <code>2425</code>；首次运行时允许本地网络访问

### 使用 Xcode 运行

~~~bash
open FeiQMac.xcodeproj
~~~

在 Xcode 中选择 <code>FeiQMac</code> Scheme 和本机 Mac，点击 Run。首次启动后：

1. 在“设置”中填写昵称、主机名和分组。
2. 点击“保存并广播”，或在未发现联系人时点击“刷新用户”。
3. 按系统提示允许本地网络、通知和截屏权限。

也可以使用命令行构建：

~~~bash
xcodebuild \
  -project FeiQMac.xcodeproj \
  -scheme FeiQMac \
  -configuration Debug \
  -sdk macosx \
  CODE_SIGNING_ALLOWED=NO \
  build
~~~

> 项目现有 Build Phase 包含签名和 DMG 打包脚本，脚本内使用 Developer ID 证书占位值并依赖 <code>create-dmg</code>。仅关闭 Xcode 自动签名不会跳过脚本内部的 <code>codesign</code>；本地调试失败时，请暂时停用该脚本，发布时再配置证书和打包工具。

## 🧩 使用方式

- **发送文字**：在输入框输入内容并发送；支持飞秋表情、输入状态和抖一抖。
- **发送图片 / 文件**：使用回形针、<code>⌘V</code>、系统截屏，或把文件拖入聊天窗口。
- **搜索记录**：使用工具栏历史搜索，按联系人、日期、关键词和内容类型组合筛选。
- **管理附件**：从侧边栏打开下载中心，查看全部传输和历史附件。
- **归档数据**：从“更多”菜单导出或导入聊天记录；导出文件旁的附件目录需要一起保存。

默认数据目录：

~~~text
~/Documents/飞秋 Mac/
├── ChatHistory.sqlite   # 联系人、会话、消息和附件元数据
├── Images/              # 本机管理的图片
├── Files/               # 本机管理的普通文件
└── Backups/             # 覆盖恢复前的安全备份
~~~

## 🔌 协议兼容与边界

| 项目 | 当前状态 |
| --- | --- |
| 网络 | IPv4 UDP/TCP <code>2425</code>，兼容飞秋 / IP Messenger 的主要发现、消息和文件通道 |
| Windows 飞秋 | 面向飞秋 2013 Windows 版；编码、图片格式和私有扩展仍建议通过真实双机验证 |
| 图片 | 支持多种 Windows 内嵌图片格式解析；发送图片默认转换为 JPEG，GIF 仅发送首帧且不保留透明度 |
| 群聊 | 当前为 **Mac 中继群**，不是 Windows 原生群聊；中继可能转发成员发给 Mac 的普通私聊，请勿加入敏感联系人 |
| 远程协助 | 仅识别并提示请求，不执行远程控制、画面传输或键鼠操作 |
| 数据与安全 | 数据库、导出记录和备份为明文；不支持离线送达、跨公网、云同步或端到端加密 |

发送限制：单张图片最大 <code>20 MB</code>，普通文件最大 <code>2 GB</code>；暂不支持文件夹层级传输、原生语音和 Windows 原生群聊。协议细节见 [feiqiu-README.md](feiqiu-README.md)，群聊前置条件见 [GROUP_INTEROP.md](GROUP_INTEROP.md)。

## 🧪 开发与验证

仓库提供独立 Swift 回归脚本，覆盖协议编码、Windows 图片解析、内嵌图片、文件传输、历史搜索与归档、拖拽发送、会话管理、下载中心、联系人身份、数据库维护和通知提示音。

运行全部检查：

~~~bash
for script in Tests/run-*-checks.sh; do
  bash "$script"
done
~~~

单独运行某一类检查，例如：

~~~bash
bash Tests/run-file-transfer-checks.sh
bash Tests/run-history-search-checks.sh
bash Tests/run-image-preview-checks.sh
~~~

检查使用临时 SQLite、模拟数据和本机 Socket，不会广播真实局域网消息，也不会操作用户实际聊天记录。它们不能替代 Windows 双机互通、真实网络切换、GUI 手势、通知声音和签名发行包验收。

## 🏗️ 技术架构

~~~text
SwiftUI View
     ↓
ViewModel
     ↓
Repository
     ↓
Service / Persistence
     ↓
UDP/TCP 2425 · SQLite · 本地附件
~~~

~~~text
FeiQMac/
├── Models/        # 消息、联系人、附件、搜索、归档和维护模型
├── Protocol/      # 飞秋报文、编码、表情和内嵌图片协议
├── Network/       # UDP/TCP、文件传输和取消控制
├── Repositories/  # 消息、附件、群组、会话和设置的业务组合
├── Services/      # 缩略图、解码、通知、备份、维护和传输调度
├── Persistence/   # SQLite 历史记录和迁移
├── ViewModels/    # 聊天、搜索、图库、归档和维护状态
└── Views/         # 聊天、设置、图库、下载中心等界面
Tests/             # 独立回归检查与运行脚本
~~~

## 🗺️ 路线与文档

- [FEATURE_ROADMAP.md](FEATURE_ROADMAP.md)：当前能力盘点与后续路线规划
- [GROUP_INTEROP.md](GROUP_INTEROP.md)：Windows 原生群聊互通所需样本和验收范围
- [feiqiu-README.md](feiqiu-README.md)：飞秋 / IP Messenger 报文参考

下一阶段重点是提升可靠性：会话草稿、消息投递状态、传输任务恢复、真实 Windows 双机验收，以及更明确的中继群隐私控制。

## 📄 许可证与免责声明

本仓库目前**未声明开源许可证**。在补充明确许可证前，请勿默认复制、修改、再分发或用于商业项目。飞秋名称、商标、Windows 客户端及相关协议资料的权利归各自权利人所有。
