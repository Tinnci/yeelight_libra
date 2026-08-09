# Yeelight Libra

macOS 菜单栏应用，用于通过局域网协议控制 Yeelight Libra 屏幕挂灯（及同协议设备）。

纯 Swift（SwiftUI + AppKit），无第三方依赖，基于 Swift Package Manager 构建。

## 功能

- 主灯：电源开关、亮度（1–100）、色温（2700–6500K）
- 背灯：电源开关、亮度、RGB 颜色选择、一键恢复默认色
- 定时关灯：30 分钟 / 1 小时 / 2 小时（使用设备端 cron，按协议直接传递分钟数）
- 背光流光：呼吸、彩虹、极光预设，可随时停止（无限循环）
- 分段背光（实验性）：左 / 右 / 整条设置 RGB，段索引因设备而异，请目视验证
- 影院模式：一键沉浸模式，主灯调暗变暖，背光以低亮度慢速环境流光（类似 Hue 动态氛围），关闭时自动恢复之前的状态
- 屏幕同步：Hue Sync 风格，实时采样屏幕边缘主色调并驱动背光（约 5Hz，带颜色迟滞防闪烁；优先走 Chroma UDP，回退 TCP 限流；需在系统设置 → 隐私与安全性 → 屏幕录制中授权后重启应用）
- 昼夜节律：根据当前时段自动平滑调整主灯色温与亮度（日出 → 正午 → 傍晚 → 夜间，线性插值，每 5 分钟评估一次；仅在主灯开启时生效）
- 日出唤醒：设定闹钟时间，到点前 N 分钟（15/30/45/60）从暗到亮、从暖到冷逐渐过渡（复用昼夜节律插值，每 15 秒评估一次）
- 定时场景：按时间自动应用场景预设（默认 19:00 阅读、21:00 放松、23:00 睡眠、8:00 专注，可单独开关并修改时间与场景，每天每个条目只应用一次）
- 系统联动：显示器休眠时自动关闭主灯与背灯，唤醒时恢复休眠前的灯效状态
- Chroma UDP 通道：可选的低延迟控制通道（UDP 55444 token 会话），开关实时反映连接状态
- Dock 菜单：打开控制面板、主灯/背灯开关与亮度快捷项、刷新状态、退出
- 设备 IP 切换：面板内直接修改，自动持久化（`UserDefaults` 键 `deviceIP`）并重建连接

定时场景在应用启动后若有多个时段已经过去，默认只应用当天最新的已过时段，避免启动时依次闪过历史场景；需要事件回放的调用方可显式选择 replay-all 策略。

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
    YeelightRequest.swift  # 类型化设备请求词汇（协议字符串仅在此处映射）
    YeelightTransport.swift # 类型化请求与具体网络传输之间的 seam
    ChromaSession.swift    # UDP Chroma 通道（token 会话、保活、重连）
    ProtocolSupport.swift   # 协议编码、能力发现、状态映射、流光表达式
    LightState.swift       # 设备状态镜像
    ScenePreset.swift      # 场景预设
    CircadianSchedule.swift # 昼夜节律时刻表（锚点 + 线性插值）
    SunriseWakeUp.swift    # 日出唤醒时刻表（窗口 / 进度 / 目标插值）
    SceneSchedule.swift    # 定时场景计划（按时应用场景预设）
    AutoModeController.swift # 智能模式（影院 / 昼夜节律 / 屏幕同步 / 日出唤醒 / 定时场景 / 显示器联动）
    AutomationArbitration.swift # 自动模式冲突策略（纯 reducer）
    AutomationDependencies.swift # 持久化、时钟、取色、显示事件适配器
    DisplayLinkState.swift # 显示器联动代次状态
    LightWorkflow.swift # 场景/恢复类型化工作流与部分失败结果
    LightControlUseCases.swift # 面板与 Dock 共用的人工控制入口与错误状态
    ScreenSyncDelivery.swift # 屏幕同步迟滞、限流与最新值合并
    ScreenColorSampler.swift  # 屏幕取色（边缘主色提取 + 截屏采样）
    MenuBarPanel.swift     # 菜单栏面板（含 AppKit NSSlider 封装）
    DockActions.swift      # Dock 菜单
    AppDelegate.swift      # 应用生命周期、状态栏项
    Logger.swift           # 文件日志
  YeelightLibra/        # 可执行入口（AppMain.swift）
Assets/
  AppIcon.png            # macOS 应用图标源图（make_app.sh 生成 AppIcon.icns）
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
