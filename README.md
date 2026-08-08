# Yeelight Libra

macOS 菜单栏应用，用于通过局域网协议控制 Yeelight Libra 屏幕挂灯（及同协议设备）。

纯 Swift（SwiftUI + AppKit），无第三方依赖，基于 Swift Package Manager 构建。

## 功能

- 主灯：电源开关、亮度（1–100）、色温（2700–6500K）
- 背灯：电源开关、亮度、RGB 颜色选择、一键恢复默认色
- 定时关灯：30 分钟 / 1 小时 / 2 小时（使用设备端 cron，30 分钟为单位）
- 背光流光：呼吸、彩虹、极光预设，可随时停止（无限循环）
- 分段背光（实验性）：左 / 右 / 整条设置 RGB，段索引因设备而异，请目视验证
- Chroma UDP 通道：可选的低延迟控制通道（UDP 55444 token 会话），开关实时反映连接状态
- Dock 菜单：打开控制面板、主灯/背灯开关与亮度快捷项、刷新状态、退出
- 设备 IP 切换：面板内直接修改，自动持久化（`UserDefaults` 键 `deviceIP`）并重建连接

## 环境要求

- macOS 14.0+（Apple Silicon 与 Intel 均可）
- 与挂灯处于同一局域网，且已开启设备的局域网控制（Yeelight 官方 App → 设置 → 局域网控制）

## 构建与运行

```bash
# 调试构建
swift build

# 打包成 .app（.build/release 二进制 + Info.plist）
./make_app.sh

# 运行打包后的应用
open YeelightLibra.app
```

> 首次运行如需 Gatekeeper 放行本地构建的 App：`xattr -dr com.apple.quarantine YeelightLibra.app`

## 使用

点击菜单栏的台灯图标打开控制面板。应用启动后自动连接默认地址 `192.168.3.111:55443`，连接失败会每 3 秒自动重试。

运行日志写入 `~/yeelight_libra.log`。

## 通信协议

| 通道 | 端口 | 说明 |
| --- | --- | --- |
| TCP | 55443 | Yeelight LAN 协议，新行分隔的 JSON 命令，`props` 异步推送状态 |
| UDP | 55444 | Chroma 会话通道：`udp_sess_new` 握手获取 token，命令携带 token 即发即忘，约每 10 秒发送 `udp_sess_keep_alive` 保活 |

## 项目结构

```
Sources/
  YeelightLibraCore/   # 业务逻辑（网络、状态、UI）
    YeelightClient.swift   # TCP 命令客户端（连接管理、重连、命令超时）
    ChromaSession.swift    # UDP Chroma 通道
    LightState.swift       # 设备状态镜像
    MenuBarPanel.swift     # 菜单栏面板（含 AppKit NSSlider 封装）
    DockActions.swift      # Dock 菜单
    AppDelegate.swift      # 应用生命周期、状态栏项
    Logger.swift           # 文件日志
  YeelightLibra/        # 可执行入口（AppMain.swift）
Tests/
  YeelightLibraTests/   # 单元测试
```

## 测试

```bash
swift test
```

覆盖 Chroma 会话生命周期与 IP 切换逻辑、`chromaConnected` 状态镜像，以及滑块"仅用户拖动才发命令、程序化更新不回环"的行为。

## 许可

[GPL-3.0](LICENSE)
