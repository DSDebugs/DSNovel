#if DEBUG
import Foundation
import SwiftData

@MainActor
enum FixtureData {
    static func isUITestFlagPresent() -> Bool {
        ProcessInfo.processInfo.arguments.contains("-DSNOVEL_UITEST")
    }

    static func populate(
        in context: ModelContext,
        emptyAll: Bool = false,
        noSourceOnly: Bool = false
    ) {
        guard !emptyAll else { return }

        if !noSourceOnly {
            let s1 = PluginRecord(
                id: "fixture_healthy",
                packageID: "pkg_fixture",
                name: "博看有声",
                version: "2.1.0",
                author: "DSNovel",
                siteURL: "https://bokan.example.com",
                summary: "经典国学与文学有声书源",
                order: 0,
                isPinned: true,
                isEnabled: true,
                searchable: true,
                discoverable: true,
                lastCheckStatus: SourceHealthState.healthy.rawValue,
                lastLatencyMs: 118,
                lastCheckedAt: .now
            )
            let s2 = PluginRecord(
                id: "fixture_need_auth",
                packageID: "pkg_fixture",
                name: "有听网",
                version: "1.4.0",
                author: "DSNovel",
                siteURL: "https://youting.example.com",
                summary: "热门长篇有声小说源",
                order: 1,
                isPinned: false,
                isEnabled: true,
                searchable: true,
                discoverable: true,
                requiresLogin: true,
                loginURL: "https://youting.example.com/login",
                loggedIn: false,
                lastCheckStatus: SourceHealthState.needAuth.rawValue,
                lastLatencyMs: 260,
                lastCheckedAt: .now
            )
            let s3 = PluginRecord(
                id: "fixture_unavailable",
                packageID: "pkg_fixture",
                name: "旧版失效源",
                version: "1.0.0",
                author: "DSNovel",
                siteURL: "https://broken.example.com",
                summary: "异常状态测试源",
                order: 2,
                isPinned: false,
                isEnabled: true,
                searchable: true,
                discoverable: true,
                lastCheckStatus: SourceHealthState.unavailable.rawValue,
                lastLatencyMs: -1,
                lastCheckMessage: "连接超时",
                lastCheckedAt: .now
            )
            context.insert(s1)
            context.insert(s2)
            context.insert(s3)
            AppSettingsStore.shared.currentDiscoverSourceID = s1.id
        }

        let titles = [
            ("诡秘之主", "爱潜水的乌贼", 2059, 102, true),
            ("人间失格（解读版）", "太宰治", 9, 2, true),
            ("少年说道：水浒传", "施耐庵", 21, 1, true),
            ("全唐诗-李白", "白云出岫", 1002, 18, true),
            ("道德经", "老子", 6, 3, true),
            ("茶花女", "小仲马", 16, 0, false),
            ("龙文鞭影", "萧良有", 30, 0, false),
            ("儒林外史", "吴敬梓", 56, 0, false),
            ("孙子兵法", "孙武", 13, 0, false),
            ("西游记", "吴承恩", 100, 0, false),
            ("红楼梦", "曹雪芹", 120, 0, false),
            ("三国演义", "罗贯中", 200, 0, false)
        ]

        for (idx, item) in titles.enumerated() {
            let bid = "fixture_healthy::https://bokan.example.com/book/\(idx + 1)"
            let hasPlayed = item.3 > 0
            let book = Book(
                id: bid,
                sourceID: "fixture_healthy",
                bookURL: "https://bokan.example.com/book/\(idx + 1)",
                title: item.0,
                author: item.1,
                inShelf: item.4,
                addedAt: Date.now.addingTimeInterval(Double(-idx * 3600)),
                lastChapterID: hasPlayed ? "https://bokan.example.com/book/\(idx + 1)/ep/\(item.3)" : nil,
                lastChapterTitle: hasPlayed ? "第 \(item.3) 章 \(item.0)" : nil,
                lastChapterIndex: item.3,
                totalChapters: item.2,
                lastPositionMs: hasPlayed ? 165_000 : 0,
                lastPlayedAt: hasPlayed ? Date.now.addingTimeInterval(Double(-idx * 1800)) : nil,
                isPinned: idx == 0,
                hasUpdate: idx == 1,
                latestChapterCount: item.2
            )
            context.insert(book)

            let chCount = (idx == 11) ? 200 : min(item.2, 20)
            let chapters = (1...chCount).map { ep in
                ChapterDTO(
                    index: ep - 1,
                    title: "第 \(ep) 章 \(item.0)",
                    url: "https://bokan.example.com/book/\(idx + 1)/ep/\(ep)",
                    durationSec: 600
                )
            }
            ChapterCacheStore.saveChapters(chapters, for: bid)
        }

        let dl1 = DownloadItem(
            id: "fixture_healthy::https://bokan.example.com/book/2::https://bokan.example.com/book/2/ep/1",
            bookID: "fixture_healthy::https://bokan.example.com/book/2",
            bookTitle: "人间失格（解读版）",
            chapterID: "https://bokan.example.com/book/2/ep/1",
            chapterTitle: "第 1 章 人间失格",
            sourceID: "fixture_healthy",
            kind: "manual",
            state: "completed",
            localPath: "fixture/ep1.mp3",
            bytes: 2_800_000
        )
        context.insert(dl1)
        try? context.save()
    }
}
#endif
