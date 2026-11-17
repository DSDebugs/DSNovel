# DSNovel 整改与验证进度表（b27 修复版）

> **验证事实声明**：本仓库在 Linux 环境下完成代码编写与 **V1（`scripts/verify_rules.sh` 静态规则与编译器规则检查）**；由于当前环境无 macOS / Xcode 26 / iOS 26 Simulator，**V2（编译）、V3（单元测试）、V4（UI 测试与截图）需在 macOS / GitHub Actions 运行验证**，**V5（G-01…G-13）需负责人在真机签字验收**。

| 任务编号 | 内容 | 代码状态 | 验证状态 |
| --- | --- | --- | --- |
| FIX-00 | 基线验证与整改前截图 | 已就绪 | 待 V2–V4（macOS 环境） |
| FIX-01 | 全局页面框架与背景统一（内联标题、`scrollContentBackground(.hidden)`、间距 20） | 已编写 | V1 通过；待 V2–V4 |
| FIX-02 | 底栏顺序（发现·搜索·书籍·我的）与 `tabViewBottomAccessory` 融合迷你播放器 | 已编写 | V1 通过；待 V2–V4 & G-11 |
| FIX-03 | 发现页书源切换胶囊、固定分类区、单源列宽 1:1 网格对齐 | 已编写 | V1 通过；待 V2–V4 |
| FIX-04 | 发现页非响应式滚动锚点、单触发分页、`DSCover` 同步命中内存缓存 | 已编写 | V1 通过；待 V2–V4 & G-10 |
| FIX-05 | 搜索页 `DSSearchField` 与 `SearchPhase` 六态状态机及 `reset()` | 已编写 | V1 通过；待 V2–V4 |
| FIX-06 | 书源互斥五态口径（带登录入口未登→需登录、过期回退、角标仅异常） | 已编写 | V1 通过；待 V2–V4 & G-12 |
| FIX-07 | 书源行去重（`DSSourceAvatar` + 单状态标签）与 `SourceListView` 统一底色 | 已编写 | V1 通过；待 V2–V4 |
| FIX-08 | 书籍页（「书籍」内联标题、最近在听 ≥2 且不重复）与我的页 | 已编写 | V1 通过；待 V2–V4 |
| FIX-09 | `SourceStore.hasEnabledSource`、`App/` 集合检查、首帧落地页防闪动 | 已编写 | V1 通过；待 V2–V4 |
| FIX-10 | 单元测试（85+）与 `DSNovelUITests` 界面断言补齐 | 已编写 | 待 V3–V4 & G-02 |
| FIX-11 | `docs/progress.md` 与 `README.md` 实事求是更正 | 已完成 | V1 通过 |
