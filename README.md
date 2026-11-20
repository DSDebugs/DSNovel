# DSNovel（iOS 26 原生架构版）

DSNovel 是一款基于 **iOS 26.0 + SwiftUI + SwiftData + AVFoundation** 构建的插件化有声书聚合播放器。

## 平台与核心特性
- **平台要求**：iOS 26.0+ / Xcode 26.0+（仅支持 iPhone，`TARGETED_DEVICE_FAMILY = "1"`）
- **四标签导航架构**：底部标签栏按 **发现 · 搜索 · 书籍 · 我的** 排列（其中「书籍」标签内主区块为「我的书架」），支持 `tabBarMinimizeBehavior(.onScrollDown)` 与 `tabViewBottomAccessory` 融合迷你播放器（含上一章 / 播放暂停 / 下一章 / 轻扫切章）。
- **首次启动内置书源说明**：首次启动时，`BundledSourceSeeder` 会自动将随包附带的 `ShunAudiobookPro-v5.6.zip` 安装到本地书源目录（幂等执行，仅首次启动安装 1 次）。
- **书源健康与登录口径**：书源状态互斥分为「已停用 / 异常 / 需登录 / 未检测 / 可用」，凡带登录入口且未登录的书源均计入「需登录」，登录过期后自动回退为「需登录」；标签栏角标仅提示「异常」书源数量。
- **设计系统 2.0**：统一 `SurfaceBase` / `SurfaceGrouped` / `SurfaceCard` / `AccentColor` / `OnAccent` 语义色令牌（全 `List`/`Form` 隐藏系统默认背景）、动态字体、`Motion` 动效令牌、`dsHaptic` 触感与 20+ 标准组件。

## 快速构建与验证
```bash
# 1. 静态规则检查（V1）
bash scripts/verify_rules.sh

# 2. 生成工程并运行测试（V2/V3/V4，需 macOS + Xcode 26）
xcodegen generate
xcodebuild test -project DSNovel.xcodeproj -scheme DSNovel -destination "platform=iOS Simulator,name=iPhone 16 Pro"
```
