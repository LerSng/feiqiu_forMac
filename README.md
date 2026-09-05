# 飞秋 Mac

一个面向 macOS 的局域网飞秋兼容客户端原型，目标是与飞秋 2013 Windows 版进行用户发现和文字聊天。

当前版本：0.1.1。

## 当前实现

- UDP 2425 广播上线、回复和离线信息
- UDP 2425 点对点文字消息和接收回执
- TCP 2425 监听（为后续文件传输保留）
- NUL 结束的 TCP 流拆包
- GB18030（兼容常见 GBK 内容）编解码
- Unicode 表情选择、发送和接收（含 UTF-8 自动标记）
- 飞秋 2013 `1_lbt6_0#...` 扩展版本头兼容
- 在线用户列表、搜索、聊天记录（当前运行期间）
- 网络诊断日志
- macOS 本地网络权限说明

## 打开和编译

使用 Xcode 打开 `FeiQMac.xcodeproj`，选择 `FeiQMac` scheme 后运行。

也可以在终端执行：

```sh
xcodebuild -project FeiQMac.xcodeproj -scheme FeiQMac -configuration Debug -sdk macosx CODE_SIGNING_ALLOWED=NO build
```

首次运行时，请在“系统设置 → 隐私与安全性 → 本地网络”允许“飞秋 Mac”，并在“系统设置 → 网络 → 防火墙 → 选项”允许该 App 接收传入连接。运行时应启动 `.app`，不要直接运行 `Contents/MacOS/FeiQMac` 可执行文件。

## 联调注意事项

Mac 和 Windows 必须在同一个局域网广播域。首次启动时允许 macOS 访问本地网络；如果 Windows 端看不到 Mac，还需要检查 Windows 防火墙是否放行 UDP/TCP 2425。

飞秋不同版本或改版可能在命令码、编码和文件传输部分存在差异。应用内“网络日志”可用于后续抓包和兼容性校准。当前版本优先覆盖文字聊天和 Unicode 表情，尚未实现文件传输和群聊。飞秋/IPMSG 的文字报文走 UDP，TCP 仅用于文件数据连接。
