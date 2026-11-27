import DSCore
import Foundation
import Observation
import os

/// 听书统计周期枚举
public enum ListeningStatsPeriod: String, CaseIterable, Identifiable, Sendable {
    case week
    case month
    case all

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .week: return "本周"
        case .month: return "本月"
        case .all: return "累计"
        }
    }

    public var heroTitle: String {
        switch self {
        case .week: return "本周累计收听"
        case .month: return "本月累计收听"
        case .all: return "累计收听总时长"
        }
    }
}

/// 书架顶部紧凑统计概览
public struct ListeningOverviewSummary: Equatable, Sendable {
    public let todaySeconds: Double
    public let weekSeconds: Double
    public let streakDays: Int

    public static let empty = ListeningOverviewSummary(todaySeconds: 0, weekSeconds: 0, streakDays: 0)
}

/// 每日柱状图单柱模型
public struct ListeningDayBar: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let seconds: Double
    public let isToday: Bool
    public let isAboveAverage: Bool
}

/// 最常听书籍排行条目
public struct ListeningBookRankItem: Identifiable, Equatable, Sendable {
    public var id: String { bookID }
    public let bookID: String
    public let bookTitle: String
    public let coverURL: String
    public let sourceID: String
    public let bookURL: String
    public let seconds: Double
    public let ratio: Double

    public func toBookSummaryDTO() -> BookSummaryDTO {
        BookSummaryDTO(id: bookID, sourceID: sourceID, sourceName: "", bookURL: bookURL, title: bookTitle, coverURL: coverURL)
    }
}

/// 单周期完整听书统计报表
public struct ListeningPeriodReport: Equatable, Sendable {
    public let period: ListeningStatsPeriod
    public let totalSeconds: Double
    public let todaySeconds: Double
    public let dailyAverageSeconds: Double
    public let streakDays: Int
    public let dailyBars: [ListeningDayBar]
    public let topBooks: [ListeningBookRankItem]
}

/// 持久化单日单书记录
public struct DailyBookListeningRecord: Codable, Equatable, Sendable {
    public let dayKey: String
    public let bookID: String
    public var bookTitle: String
    public var coverURL: String
    public var sourceID: String
    public var bookURL: String
    public var seconds: Double

    public init(dayKey: String, bookID: String, bookTitle: String, coverURL: String, sourceID: String, bookURL: String, seconds: Double) {
        self.dayKey = dayKey; self.bookID = bookID; self.bookTitle = bookTitle
        self.coverURL = coverURL; self.sourceID = sourceID; self.bookURL = bookURL; self.seconds = seconds
    }
}

/// 本地轻量听书统计仓库（按「日期 × 书籍」聚合真实播放秒数，原子 JSON 落盘，零外部依赖）
@Observable
@MainActor
public final class ListeningStatsStore {
    public private(set) var overview: ListeningOverviewSummary = .empty
    public private(set) var revision: UInt64 = 0

    private struct VersionedPayload: Codable { let version: Int; let records: [DailyBookListeningRecord] }
    private static let logger = Logger(subsystem: "com.dsnovel.app", category: "ListeningStatsStore")
    private let fileURL: URL?
    private var recordsByCompositeKey: [String: DailyBookListeningRecord] = [:]
    private var pendingFlushSeconds: Double = 0
    private var lastFlushDate: Date = .distantPast
    private var lastOverviewComputeDate: Date = .distantPast

    public init(storageDirectory: URL?) {
        self.fileURL = storageDirectory?.appendingPathComponent("listening_stats_v1.json")
        loadFromDisk()
        recomputeOverview()
    }

    /// 累计真实播放时长（仅在播放态触发，自动按日 × 书聚合，每 10 秒批量原子落盘）
    public func recordListening(book: BookSummaryDTO, deltaSeconds: Double, at date: Date = Date()) {
        guard deltaSeconds.isFinite, deltaSeconds > 0 else { return }
        let clamped = min(deltaSeconds, 10.0)
        let dayKey = Self.dayKey(for: date)
        let key = "\(dayKey)::\(book.id)"

        if var existing = recordsByCompositeKey[key] {
            existing.seconds += clamped
            if !book.title.isEmpty { existing.bookTitle = book.title }
            if !book.coverURL.isEmpty { existing.coverURL = book.coverURL }
            if !book.sourceID.isEmpty { existing.sourceID = book.sourceID }
            if !book.bookURL.isEmpty { existing.bookURL = book.bookURL }
            recordsByCompositeKey[key] = existing
        } else {
            recordsByCompositeKey[key] = DailyBookListeningRecord(
                dayKey: dayKey,
                bookID: book.id,
                bookTitle: book.title,
                coverURL: book.coverURL,
                sourceID: book.sourceID,
                bookURL: book.bookURL,
                seconds: clamped
            )
        }

        let isFirstDelta = (pendingFlushSeconds == 0)
        pendingFlushSeconds += clamped
        if isFirstDelta || date.timeIntervalSince(lastOverviewComputeDate) >= 2.0 {
            recomputeOverview(referenceDate: date)
        }
        revision &+= 1
        if pendingFlushSeconds >= 10.0 || date.timeIntervalSince(lastFlushDate) >= 15.0 {
            recomputeOverview(referenceDate: date)
            flushToDisk()
        }
    }

    private static let ioQueue = DispatchQueue(label: "com.dsnovel.app.listeningStats.io", qos: .utility)

    private func takeFlushPayload() -> (URL, VersionedPayload, Double)? {
        guard pendingFlushSeconds > 0, let url = fileURL else { return nil }
        let amount = pendingFlushSeconds
        pendingFlushSeconds = 0
        lastFlushDate = Date()
        return (url, VersionedPayload(version: 1, records: Array(recordsByCompositeKey.values)), amount)
    }

    public func flushToDisk() {
        guard let (url, payload, amount) = takeFlushPayload() else { return }
        Self.ioQueue.async { [weak self] in
            do {
                try JSONEncoder().encode(payload).write(to: url, options: .atomic)
            } catch {
                Self.logger.error("flushToDisk failed: \(error.localizedDescription, privacy: .public)")
                Task { @MainActor [weak self] in self?.pendingFlushSeconds += amount }
            }
        }
    }

    public func flushToDiskAsync() async {
        guard let (url, payload, amount) = takeFlushPayload() else {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                Self.ioQueue.async { cont.resume() }
            }
            return
        }
        let failed = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            Self.ioQueue.async {
                do {
                    try JSONEncoder().encode(payload).write(to: url, options: .atomic)
                    cont.resume(returning: false)
                } catch {
                    Self.logger.error("flushToDiskAsync failed: \(error.localizedDescription, privacy: .public)")
                    cont.resume(returning: true)
                }
            }
        }
        if failed { pendingFlushSeconds += amount }
    }

    public func report(for period: ListeningStatsPeriod, referenceDate: Date = Date()) -> ListeningPeriodReport {
        Self.buildReport(
            records: Array(recordsByCompositeKey.values),
            period: period,
            referenceDate: referenceDate
        )
    }

    private func loadFromDisk() {
        guard let url = fileURL, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let decoded: [DailyBookListeningRecord]
            if let wrapped = try? decoder.decode(VersionedPayload.self, from: data) {
                guard wrapped.version == 1 else { throw CocoaError(.coderReadCorrupt) }
                decoded = wrapped.records
            } else {
                decoded = try decoder.decode([DailyBookListeningRecord].self, from: data)
            }
            var map: [String: DailyBookListeningRecord] = [:]
            for item in decoded where item.seconds > 0 { map["\(item.dayKey)::\(item.bookID)"] = item }
            recordsByCompositeKey = map
        } catch {
            Self.logger.error("loadFromDisk failed, backing up corrupted file: \(error.localizedDescription, privacy: .public)")
            let backupURL = url.deletingLastPathComponent().appendingPathComponent("listening_stats_v1.corrupted-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: backupURL)
        }
    }

    private func recomputeOverview(referenceDate: Date = Date()) {
        lastOverviewComputeDate = referenceDate
        overview = Self.computeOverview(records: Array(recordsByCompositeKey.values), referenceDate: referenceDate)
    }
}
