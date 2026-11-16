# DSNovel (iOS)

基于 SwiftUI 全量重写的插件驱动型有声书/听书聚合播放器（仅支持 iPhone · 控制层 Liquid Glass 规范）。

## 核心特性

- **固定四标签架构**：`发现` · `书架` · `搜索` · `设置`，单向模块依赖，零第三方运行时依赖。
- **100% 兼容 SSTS 插件包（`.zip`）**：内置校准后的 `prelude.js`、`JavaScriptCore` 独立沙箱（15 秒超时重建、5 分钟空闲回收）、`JsElement` CSS 选择器引擎与 `CommonCrypto` AES-ECB/MD5 宿主桥，可导入你自己的 `.zip` 书源包或单个 `.js` 书源脚本。**应用不内置任何书源**，首次使用需在「设置 → 书源管理」导入。
- **控制层玻璃、内容层干净**：仅在底部标签栏、导航工具栏、迷你播放条、书架多选悬浮栏与播放主控组使用 `GlassEffectContainer`，自动适配系统「降低透明度」无障碍设置。
- **高性能数据与图片管线**：SwiftData 持久化书架/分类/书签/下载/插件，章节列表使用 `Compression` 框架 `LZFSE` 压缩缓存（`Caches/chapters/<bookID>.json.lzfse`），封面图片采用 `ImageIO` 按像素尺寸降采样（64 MB 内存上限 / 200 MB 磁盘上限）。

## GitHub Actions 自动生成未签名 IPA

将本工程推送到 GitHub 仓库后，`.github/workflows/ios-ipa-build.yml` 会自动执行：
1. `xcodegen generate` 生成 `DSNovel.xcodeproj`
2. 运行 `DSNovelTests` 单元测试
3. 编译 Release 架构并打包生成 `DSNovel-unsigned.ipa`，上传至 Actions Artifacts。
