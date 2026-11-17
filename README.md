# DSNovel（iOS 26 原生架构版）

DSNovel 是一款基于 **iOS 26.0 + SwiftUI + SwiftData + AVFoundation** 构建的插件化有声书聚合播放器。

## 平台与核心特性
- **平台要求**：iOS 26.0+ / Xcode 26.0+（仅支持 iPhone，`TARGETED_DEVICE_FAMILY = "1"`）
- **首次启动内置书源说明**：首次启动时，`BundledSourceSeeder` 会自动将随包附带的 `ShunAudiobookPro-v5.6.zip` 安装到本地书源目录（幂等执行，仅首次启动安装 1 次，不会覆盖用户自定义配置）。若无已启用书源，应用将展示首次启动引导页。
- **全局导航与外壳（`AppShell`）**：采用系统 `TabView` 四标签架构（**书架 · 发现 · 我的 · 搜索**），内置底部迷你播放器（`MiniPlayer`）与顶部反馈中心（`BannerCenter`），支持重复点击标签回退根视图或滚动回顶。
- **设计系统 2.0**：统一语义色令牌（`SurfaceBase`、`SurfaceGrouped`、`SurfaceCard`、`AccentColor`、`OnAccent`，含深色模式「夜间降亮」）、动态字体样式（`DSTypography`）、间距与圆角令牌（`Spacing`、`Radius`）、动效令牌（`Motion` + `dsReduceMotion`）、触感反馈（`dsHaptic`）以及 18+ 标准组件。
- **数据与状态层（4 大 Store）**：`LibraryStore`、`DiscoverStore`、`SourceStore`、`SearchStore` 统一驱动派生状态，配合 `ChapterProgressCache`（SwiftData `ChapterProgress` + 内存缓存与节流持久化）。
- **封面缓存与后台下载**：
  - `CoverImagePipeline` 实现 80 MB 内存缓存上限、200 MB 磁盘 LRU 淘汰（超限自动清理至 70%，30 秒节流）与同 URL 并发请求合并。
  - `DownloadManager` + `BackgroundDownloadSession` 支持后台下载会话（`com.dsnovel.downloads`）、增量汇总、磁盘空间预检、`waitingWiFi` 状态、断点续传（`resumeData`）及 5 秒可撤销延迟删除。详见 `docs/downloads.md`。

## 快速构建与验证
```bash
# 1. 运行架构与设计规范静态检查（V1）
bash scripts/verify_rules.sh

# 2. 生成 Xcode 工程并构建（V2/V3）
xcodegen generate
xcodebuild test -project DSNovel.xcodeproj -scheme DSNovel -destination "platform=iOS Simulator,name=iPhone 16 Pro"
```
