import DSCore
import DSDesignSystem
import Foundation

/// 100 章区间分段模型（1:1 复刻 v2.8）
struct ChapterSegmentItem: Identifiable, Equatable, Hashable, Sendable {
    var id: Int { startIndex }
    let startIndex: Int
    let endIndex: Int
    var label: String { "\(startIndex + 1)–\(endIndex)" }
}

/// 单章下载状态（1:1 复刻 v2.8）
enum ChapterDownloadState: Equatable, Hashable, Sendable {
    case notDownloaded
    case downloading(Double)
    case completed
    case failed
}

/// 单章展示快照（严格使用数组真实下标 arrayIndex，彻底杜绝重复 ID 错播）
struct ChapterRowSnapshot: Identifiable, Equatable, Hashable, Sendable {
    var id: String { "\(arrayIndex)::\(chapter.id)" }
    let arrayIndex: Int
    let chapter: ChapterDTO
    let displayIndex: Int
    let isCurrentPlayingChapter: Bool
    let isEnginePlaying: Bool
    let savedPositionMs: Int
    let durationMs: Int
    let isFinished: Bool
    let isVIP: Bool
    let downloadState: ChapterDownloadState
    let downloadedBytes: Int64
    let downloadStatusNote: String?
    let displayTitle: String
    let downloadRecordID: String

    var effectiveDurationMs: Int {
        if durationMs > 0 { return durationMs }
        return chapter.durationMs
    }

    func subtitleText(overridePositionMs: Int? = nil, overrideDurationMs: Int? = nil) -> String {
        let posMs = overridePositionMs ?? savedPositionMs
        let durMs = (overrideDurationMs ?? 0) > 0 ? (overrideDurationMs ?? 0) : effectiveDurationMs
        var parts: [String] = []
        if durMs > 0 {
            parts.append(DSScrubberLogic.formatTime(Double(durMs) / 1000.0))
        }

        if isFinished {
            parts.append("已播完")
        } else if posMs > 0 {
            if durMs > 0 {
                let pct = min(99, max(1, Int((Double(posMs) / Double(durMs) * 100.0).rounded())))
                parts.append("已播 \(pct)%")
            } else {
                parts.append("已播")
            }
        }

        switch downloadState {
        case .completed:
            if downloadedBytes > 0 {
                let sizeStr = ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
                parts.append("已下载 · \(sizeStr)")
            } else {
                parts.append("已下载")
            }
        case .downloading(let progress):
            if let note = downloadStatusNote, !note.isEmpty {
                parts.append(note)
            } else {
                parts.append("下载中 \(Int((progress * 100).rounded()))%")
            }
        case .failed:
            parts.append("下载失败 · 点击重试")
        case .notDownloaded:
            break
        }
        return parts.joined(separator: " · ")
    }

    var subtitleText: String {
        subtitleText()
    }
}

/// 本书下载状态汇总
struct BookDownloadOverview: Equatable, Sendable {
    let completedCount: Int
    let activeCount: Int
    let failedCount: Int
    let totalBytes: Int64
    let recordsByChapterID: [String: DownloadRecordSnapshot]

    static let empty = BookDownloadOverview(
        completedCount: 0,
        activeCount: 0,
        failedCount: 0,
        totalBytes: 0,
        recordsByChapterID: [:]
    )
}

/// 书籍详情纯数据辅助器（独立于 View 文件，严格遵守规则 #8 无 body 内集合操作）
enum BookDetailHelper {
    static let emptyIntroPlaceholder = "暂无作品简介"

    static func buildSegments(totalCount: Int, pageSize: Int = 100) -> [ChapterSegmentItem] {
        guard totalCount > 0, pageSize > 0 else { return [] }
        var list: [ChapterSegmentItem] = []
        var start = 0
        while start < totalCount {
            let end = min(start + pageSize, totalCount)
            list.append(ChapterSegmentItem(startIndex: start, endIndex: end))
            start = end
        }
        return list
    }

    static func cleanHTML(_ raw: String) -> String {
        guard !raw.isEmpty else { return emptyIntroPlaceholder }
        let stripped = raw
            .replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "([0-9]+)\\s*\u{96C6}", with: "$1 章", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? emptyIntroPlaceholder : stripped
    }

    static func hasIntroContent(_ cleanedIntro: String) -> Bool {
        let trimmed = cleanedIntro.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != emptyIntroPlaceholder
    }

    static func summarizeDownloads(
        bookID: String,
        records: [DownloadRecordSnapshot]
    ) -> BookDownloadOverview {
        var completed = 0
        var active = 0
        var failed = 0
        var totalBytes: Int64 = 0
        var map: [String: DownloadRecordSnapshot] = [:]

        for rec in records where rec.bookID == bookID {
            map[rec.chapterID] = rec
            switch rec.state {
            case .completed:
                completed += 1
                totalBytes += max(0, rec.totalBytes)
            case .queued, .resolving, .downloading, .paused:
                active += 1
            case .failed:
                failed += 1
            case .cancelled:
                break
            }
        }
        return BookDownloadOverview(
            completedCount: completed,
            activeCount: active,
            failedCount: failed,
            totalBytes: totalBytes,
            recordsByChapterID: map
        )
    }

    static func buildSnapshots(
        bookTitle: String,
        chapters: [ChapterDTO],
        segments: [ChapterSegmentItem],
        selectedSegmentIndex: Int,
        isShowingDownloadedOnly: Bool,
        isAscending: Bool,
        searchKeyword: String,
        currentPlayingIndex: Int?,
        isEnginePlaying: Bool,
        finishedIndices: Set<Int>,
        downloadOverview: BookDownloadOverview,
        isWaitingForWiFi: Bool
    ) -> [ChapterRowSnapshot] {
        guard !chapters.isEmpty else { return [] }
        let kw = searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let baseSlice: [(index: Int, chapter: ChapterDTO)]
        if !kw.isEmpty {
            var matched: [(index: Int, chapter: ChapterDTO)] = []
            for (idx, ch) in chapters.enumerated() {
                if ch.title.lowercased().contains(kw) || "\(idx + 1)".contains(kw) {
                    matched.append((idx, ch))
                }
            }
            baseSlice = matched
        } else if isShowingDownloadedOnly {
            baseSlice = chapters.enumerated().map { ($0.offset, $0.element) }
        } else if segments.indices.contains(selectedSegmentIndex) {
            let seg = segments[selectedSegmentIndex]
            let start = min(max(0, seg.startIndex), chapters.count)
            let end = min(max(start, seg.endIndex), chapters.count)
            baseSlice = (start..<end).map { ($0, chapters[$0]) }
        } else {
            baseSlice = chapters.enumerated().map { ($0.offset, $0.element) }
        }

        let ordered = isAscending ? baseSlice : Array(baseSlice.reversed())
        let bookMainTitle = BookTitleFormatter.split(BookTitleFormatter.cleanTitle(bookTitle)).main

        var results: [ChapterRowSnapshot] = []
        results.reserveCapacity(ordered.count)

        for pair in ordered {
            let idx = pair.index
            let ch = pair.chapter
            let rec = downloadOverview.recordsByChapterID[ch.id]
            let dlState: ChapterDownloadState
            var dlBytes: Int64 = 0
            var statusNote: String? = nil
            let recordID = rec?.id ?? ""

            if let rec {
                dlBytes = max(0, rec.totalBytes)
                switch rec.state {
                case .completed:
                    dlState = .completed
                case .downloading:
                    let ratio = rec.totalBytes > 0
                        ? min(1, max(0.05, Double(rec.downloadedBytes) / Double(rec.totalBytes)))
                        : 0.15
                    dlState = .downloading(ratio)
                case .resolving:
                    dlState = .downloading(0.08)
                    statusNote = "解析地址中"
                case .queued:
                    dlState = .downloading(0.05)
                    statusNote = isWaitingForWiFi ? "等待 Wi-Fi" : "排队下载中"
                case .paused:
                    dlState = .downloading(0.05)
                    statusNote = isWaitingForWiFi ? "等待 Wi-Fi" : "已暂停"
                case .failed:
                    dlState = .failed
                case .cancelled:
                    dlState = .notDownloaded
                }
            } else {
                dlState = .notDownloaded
            }

            if isShowingDownloadedOnly && dlState == .notDownloaded {
                continue
            }

            let isCurrent = (currentPlayingIndex == idx)
            results.append(
                ChapterRowSnapshot(
                    arrayIndex: idx,
                    chapter: ch,
                    displayIndex: idx + 1,
                    isCurrentPlayingChapter: isCurrent,
                    isEnginePlaying: isCurrent && isEnginePlaying,
                    savedPositionMs: 0,
                    durationMs: ch.durationMs,
                    isFinished: finishedIndices.contains(idx),
                    isVIP: ch.isVIP || ch.title.uppercased().contains("VIP"),
                    downloadState: dlState,
                    downloadedBytes: dlBytes,
                    downloadStatusNote: statusNote,
                    displayTitle: BookTitleFormatter.stripBookPrefix(from: ch.title, bookMainTitle: bookMainTitle),
                    downloadRecordID: recordID
                )
            )
        }
        return results
    }

    static func locateTargetIndex(
        chaptersCount: Int,
        currentPlayingIndex: Int?,
        resumeChapterIndex: Int?
    ) -> Int? {
        guard chaptersCount > 0 else { return nil }
        if let playing = currentPlayingIndex, playing >= 0, playing < chaptersCount {
            return playing
        }
        if let saved = resumeChapterIndex, saved >= 0, saved < chaptersCount {
            return saved
        }
        return nil
    }
}
