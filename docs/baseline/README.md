# DSNovel 性能基线记录（T0-01）

> **重要说明：** 本次自动化基线测试（`DSNovelTests/Performance/BaselinePerfTests.swift`）面向 CI 模拟器回归对比，**模拟器测量结果不代表真机实际帧率与能耗**。真机 Instruments 基线由负责人按照 §5 G-01 完成采集并归档于 `docs/baseline/device/`。

## 1. 自动化基线测试运行方式

```bash
xcodegen generate
xcodebuild test \
  -project DSNovel.xcodeproj \
  -scheme DSNovel \
  -destination "platform=iOS Simulator,name=<已安装的 iOS 26 iPhone>" \
  -only-testing:DSNovelTests/BaselinePerfTests
```

## 2. 自动化测量项（模拟器回归对比）

| 用例名 | 夹具规模 | 度量指标 | 用途 |
| --- | --- | --- | --- |
| `testShelfDerivationPerformance500Books` | 500 本 `Book` | `XCTClockMetric` / `XCTMemoryMetric` | 对比 P3 `LibraryStore` 后台派生前后的耗时与内存峰值 |
| `testChapterSegmentBuilding2000Chapters` | 2000 章 `ChapterDTO` | `XCTClockMetric` / `XCTMemoryMetric` | 对比 P4 详情页章节分段与虚拟列表构建耗时 |
| `testDiscoverSubtitleDerivation200Items` | 200 条 `BookRef` | `XCTClockMetric` | 校验发现页批量副标题解析耗时 |

## 3. 真机 Instruments 基线采集清单（负责人执行 · G-01）

真机 Release 构建下通过 Instruments 采集并存档于 `docs/baseline/device/` 的 6 项核心指标：
1. **App Launch（冷启动到可交互耗时）**：目标 `< 1.0 s`。
2. **Animation Hitches（动画掉帧比）**：覆盖书架 500 本滚动、发现 200 项滚动、进入书籍详情缩放转场（M1）、展开全屏播放器转场（M2），目标 `< 5 ms/s`，90 分位帧时间 `≤ 8.3 ms`（120Hz）或 `≤ 16.6 ms`（60Hz）。
3. **Time Profiler（主线程耗时分布）**：确认列表滚动与播放进度跳秒期间主线程无同步磁盘 I/O 或全表重排。
4. **Allocations（内存分配峰值）**：书架 500 本连续滚动内存峰值 `< 250 MB`。
5. **播放 30 分钟 CPU 占用**：锁屏与前台播放全屏页 30 分钟平均 CPU `< 10%`。
6. **封面缓存目录磁盘增长**：连续浏览 1000 张封面后，`Caches/CoverCache` 稳定控制在 `≤ 200 MB` 上限内。
