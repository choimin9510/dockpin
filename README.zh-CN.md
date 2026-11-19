# Dockpin

[English](README.md) · [한국어](README.ko.md)

Dockpin 是一款 macOS 菜单栏应用，可将 Dock 固定到指定显示器，并在睡眠、显示器休眠或重新连接后恢复窗口布局。该个人使用应用已在 Apple Silicon 和 macOS 26.3.1 上验证。最低支持 macOS 13；本地构建使用临时签名，未经公证。

## 开始使用

使用 Xcode Command Line Tools 构建并启动：

```sh
./scripts/build.sh
open build/Dockpin.app --args --show
```

1. 在系统设置 → 隐私与安全性 → 辅助功能中允许 Dockpin。
2. 启用自动恢复，记录当前窗口布局。
3. 如需恢复 Dock 大小，在应用中允许 System Events 自动化权限。
4. 选择 Dock 所在显示器。确认当前布局符合预期后，可使用“记住当前布局”更新基准。

“立即恢复”应用上次保存的布局；记住当前布局会替换受保护的原有基准。替换本地构建后可能需要重新授予辅助功能权限。

## 工作方式

布局按显示器配置保存，显示器通过 UUID 识别。恢复会等待显示器配置稳定且用户停止输入，缺失的显示器最多等待 60 秒。用户拖动过的窗口会从本次恢复中排除。恢复开始后至少观察 30 秒，并要求窗口保持正确 3 秒；首次重试最多持续 60 秒，应用延迟改变尺寸时会再次恢复。失败窗口和 Dock 设置分别保留目标，正常窗口继续保存。恢复跟踪 30 秒后，在无输入时仅重试失败目标，每轮最多 10 秒。检查自动化权限前会在后台启动 System Events，避免将进程未运行误判为拒绝授权。

Dock 移动要求 Dock 位于屏幕底部并启用“显示器具有单独的空间”。如果目标显示器底部被其他屏幕遮挡或菜单处于打开状态，移动可能失败。DockLock 运行期间，Dock 控制会等待。

应用可恢复允许辅助功能接口调整的普通窗口及 AgentBoard 主面板。不支持全屏、分屏、最小化或隐藏的窗口，不支持跨桌面移动窗口或重新打开已关闭的应用和窗口。应用自身的最小尺寸或辅助功能实现也可能阻止恢复。

布局保存在本地 `~/Library/Application Support/Dockpin/Layouts/`，可能包含应用标识、进程启动时间、窗口标题和文档标识。目录权限为 700，文件权限为 600。Dockpin 不会传输这些数据，也不会录屏。状态文件位于 `~/Library/Logs/`。

## 测试

```sh
./scripts/test.sh
.build/native/Dockpin --self-test
./scripts/test-integration.sh
codesign --verify --deep --strict build/Dockpin.app
```

集成测试需要终端的辅助功能权限，会暂时移动测试窗口和 Dock；测试期间请勿使用鼠标和键盘，并先退出其他 Dock 控制应用。完整系统睡眠和物理线缆重新连接仍需实际验证。更多行为细节和既有验证结果请参阅[韩文文档](README.ko.md)。

## 0.2.3 鼠标边缘处理

非目标显示器底部的鼠标移动不再被丢弃，也不再强制跳转光标。仅修正向下的压力，保留横向移动、向上离开、Option 绕过和跨显示器移动。`./scripts/test-pointer.sh --live` 可验证实际光标与 Dock，运行前退出 Dockpin 并暂停输入约 5 秒。
