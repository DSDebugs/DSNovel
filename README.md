# DSNovel v3.3.9（绿地全量重写）

DSNovel v3.3.9 基于 **Swift 6.0 严格并发 + XcodeGen + 6 个本地 Swift Package（零外部 SPM 依赖）+ 纯 iPhone 竖屏 Liquid Glass UI** 全量重写，固化了 v2.8 b1–b105 与 GitHub Actions 自签 IPA 的全部 12 条实战经验教训。

## 架构分层（单向依赖 DAG）
1. `DSCore`：DTO、强类型状态机（`PlaybackState` / `DownloadState`）、密码学/CRC-32、严格 `ZIPArchiveReader`、`DSDiagnosticLogStore` 与冻结协议。
2. `DSStorage`：SwiftData v3 7 张干净数据表、`@ModelActor PersistenceEngine`、`DSLZ/DSJS` 魔数头 `ChapterCacheStore`、`SQLITE_CHECKPOINT_TRUNCATE` 5 份 WAL 备份与 `LibraryBackupCodec`。
3. `DSPluginKit`：ES5 沙箱 `PluginRuntime`、独立 `BuiltinParserEngine`（成对原子回滚）、零依赖纯 Swift `HTMLDocumentNode`、`SSRFGuard`、302 跨域 Cookie 剥离 `HostHTTPClient`、`CookieVault` 与 Q5 兼容放行策略。
4. `DSDesignSystem`：液态玻璃主题与动态字体令牌、防 200 HTML 假封面的 `CoverImagePipeline`、单横幅 `DSSheetScaffold`、`DSBottomBar` 与上滑精调 `DSScrubber`。
5. `DSPlayback`：`PlaybackCoordinator`、`PlaybackClock`、`AudioTapDSP`（800ms 看门狗降级无后缀 HLS）、墙钟 `SleepTimerEngine` 与线控/中断处理器。
6. `DSDownloads`：`DownloadCoordinator`、双池 `DownloadScheduler`（manual 优先防 precache 饥饿）、`BackgroundTransferTransport`（`.pending_staging` 兜底）与 60s 节流 `StorageReconciler`。

## GitHub Actions 自签 IPA
推送至 GitHub 即可触发 `.github/workflows/ios-ipa-build.yml`（`macos-26`）：
1. `scripts/verify_rules.sh`（22 条静态门禁，零豁免，含单文件 ≤400 行）
2. `ep_selfcheck.js`（27/27）+ `ep_fuzz.js` + 内置 JS 语法与无 BOM 校验
3. `xcodegen generate` + `xcodebuild test`（6 个本地 SPM 包 + 主 App iOS 模拟器单测与 UI 冒烟测试）
4. `xcodebuild build`（`-configuration Release -sdk iphoneos`，无证书禁签参数）+ 8 项必含资源及二进制/压缩包完整性校验（缺失即 `exit 1`）+ 产出 `DSNovel-v3.3.9-b<N>.ipa`（Bundle ID：`com.dsnovel.app`）。
