# DSNovel 重构任务进度表（P0–P6 全部完成）

| 阶段 | 任务编号 | 标题 | 状态 | 验证等级与备注 |
| --- | --- | --- | --- | --- |
| P0 | T0-01 | 性能基线记录 (`BaselinePerfTests.swift` + `docs/baseline/README.md`) | 已完成 | V1 通过；待 G-01 真机基线 |
| P0 | T0-02 | 升级工具链、部署目标 (iOS 26.0) 与 CI (`verify_rules.sh`) | 已完成 | V1 通过 |
| P0 | T0-03 | 隔离自定义玻璃类型 | 已完成 | V1 通过（已在 T4-5 彻底删除） |
| P0 | T0-04 | 数据库初始化失败降级 (`DataRepairView`) 与 `StoreBackup` | 已完成 | V1 通过；含 `StoreBackupTests` |
| P0 | T0-05 | 章节进度时间戳淘汰过渡修复 (`ChapterProgressStore`) | 已完成 | V1 通过；含 `ChapterProgressStoreTests` |
| P0 | T0-06 | 封面缓存磁盘 LRU 淘汰与并发请求合并 (`CoverImagePipeline`) | 已完成 | V1 通过；含 `CoverPipelineTests` |
| P0 | T0-07 | 测试底座 (`TestContainer`)、UI 冒烟测试与快照基线文档 | 已完成 | V1 通过；待 G-02 批准快照 |
| P1 | T1-01…T1-10 | 设计系统 2.0（颜色/字体/间距/圆角/动效/触感/18+组件/`BannerCenter`/`DSGalleryView`） | 已完成 | V1 通过；含 `DesignSystemTests` |
| P2 | T2-00…T2-05 | 夹具模式、`AppRouter`、`AppShell`、`MiniPlayer`、删除自绘 Dock | 已完成 | V1 通过；含 `AppRouterAndShellTests`；待 G-03 |
| P3 | T3-01…T3-06 | 四大 Store、`ChapterProgress` SwiftData 迁移、`Book` 更新检查、`DownloadManager` 与后台下载会话 | 已完成 | V1 通过；含 `StoresTests` 与 `DownloadAndProgressTests`；待 G-04 |
| P4 | T4-1a…T4-6e | 书架、历史、发现、详情、搜索、全屏播放器、我的、书源、下载管理、认证、引导及旧代码清理 | 已完成 | V1 通过（`rules_allowlist.txt` 已清零）；待 G-05 / G-06 / G-07 |
| P5 | T5-01…T5-13 | 标准动效、封面渐显、骨架屏、选中指示器、均衡器、触感全覆盖与氛围背景降级 | 已完成 | V1 通过；待 G-01 / G-08 |
| P6 | T6-01 | 无障碍专项复查 | 已取消（D-3） | 按 §0 决策取消 |
| P6 | T6-02 | 夜间降亮与应用内「减弱动画」覆盖 | 已完成 | V1 通过；含对比度单测 |
| P6 | T6-03 | 备份与恢复 | 已取消（D-3） | 按 §0 决策取消 |
| P6 | T6-04 | 文档与清理（术语统一为「章」、移除全部 `deprecated`） | 已完成 | V1 通过 |
| P6 | T6-05 | 发布候选验收与检查表汇总 | 已完成 | V1 全部通过；待负责人执行 §5 人工门 G-01…G-09 |
