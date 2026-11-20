# DSNovel 后台下载机制与系统限制说明

## 1. 架构说明（T3-04 & T3-06）
- **后台传输会话**：使用 `URLSessionConfiguration.background(withIdentifier: "com.dsnovel.downloads")`，由 `BackgroundDownloadSession` 托管下载任务并通过 `AppDelegate` 处理系统后台唤醒回调。
- **直链解析与接力**：由于书源与内置解析需要在 App 进程的 JavaScriptCore 运行时内解析音频直链，后台单个章节下载完成后，会在 `UIApplication.beginBackgroundTask` 窗口内尽力解析并提交下一排队章节；若后台执行窗口耗尽或解析受阻，任务保持 `queued`，待回到前台后自动恢复调度。
- **内置解析直链续期**：若下载返回 `401 / 403 / 410` 且直链来自内置解析（`BuiltinParserRuntime.resolverTag`），自动作废解析缓存并触发重解析。
- **暂停与断点续传**：暂停下载时调用 `cancel(byProducingResumeData:)` 将断点数据保存在 `Caches/DownloadResumeData/`，恢复时优先使用断点数据续传。

## 2. iOS 系统级已知限制（非应用缺陷）
1. **上划强退 App**：若用户在系统多任务切换界面**手动向上划掉** DSNovel，iOS 系统会立即取消该应用的全部后台传输会话并禁止后台唤醒，未完成任务将在下次启动时经 `recoverInterruptedItems()` 对账后回到排队状态。
2. **付费/动态签名直链过期**：部分内置解析或防盗链书源生成的音频直链有效期较短（如 5–15 分钟），锁屏长时间排队后直链可能过期，需回到前台或后台唤醒窗口重新解析。
