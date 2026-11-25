import DSCore
import Foundation
import Observation

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

    private let fileURL: URL?
    private var recordsByCompositeKey: [String: DailyBookListeningRecord] = [:]
    private var pendingFlushSeconds: Double = 0
    private var lastFlushDate: Date = .distantPast

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

        pendingFlushSeconds += clamped
        recomputeOverview(referenceDate: date)
        revision &+= 1

        if pendingFlushSeconds >= 10.0 || date.timeIntervalSince(lastFlushDate) >= 15.0 {
            flushToDisk()
        }
    }

    private static let ioQueue = DispatchQueue(label: "com.dsnovel.app.listeningStats.io", qos: .utility)

    private func takeFlushPayload() -> (URL, [DailyBookListeningRecord])? {
        guard pendingFlushSeconds > 0, let url = fileURL else { return nil }
        pendingFlushSeconds = 0
        lastFlushDate = Date()
        return (url, Array(recordsByCompositeKey.values))
    }

    public func flushToDisk() {
        guard let (url, snapshot) = takeFlushPayload() else { return }
        Self.ioQueue.async { if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) } }
    }

    public func flushToDiskAsync() async {
        guard let (url, snapshot) = takeFlushPayload() else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            Self.ioQueue.async {
                if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
                cont.resume()
            }
        }
    }

    public func report(for period: ListeningStatsPeriod, referenceDate: Date = Date()) -> ListeningPeriodReport {
        Self.buildReport(
            records: Array(recordsByCompositeKey.values),
            period: period,
            referenceDate: referenceDate
        )
    }

    private func loadFromDisk() {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([DailyBookListeningRecord].self, from: data) else {
            return
        }
        var map: [String: DailyBookListeningRecord] = [:]
        for item in decoded where item.seconds > 0 {
            map["\(item.dayKey)::\(item.bookID)"] = item
        }
        recordsByCompositeKey = map
    }

    private func recomputeOverview(referenceDate: Date = Date()) {
        overview = Self.computeOverview(records: Array(recordsByCompositeKey.values), referenceDate: referenceDate)
    }

    // MARK: - Pure Aggregation & Formatting Helpers

    public nonisolated static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
    }

    public nonisolated static func computeOverview(
        records: [DailyBookListeningRecord],
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> ListeningOverviewSummary {
        let todayKey = dayKey(for: referenceDate, calendar: calendar)
        var secondsByDay: [String: Double] = [:]
        for rec in records where rec.seconds > 0 {
            secondsByDay[rec.dayKey, default: 0] += rec.seconds
        }

        let todaySec = secondsByDay[todayKey] ?? 0
        let weekKeys = Set(currentWeekDates(around: referenceDate, calendar: calendar).map { dayKey(for: $0, calendar: calendar) })
        let weekSec = weekKeys.reduce(0.0) { $0 + (secondsByDay[$1] ?? 0) }
        let streak = computeStreakDays(secondsByDay: secondsByDay, referenceDate: referenceDate, calendar: calendar)
        return ListeningOverviewSummary(todaySeconds: todaySec, weekSeconds: weekSec, streakDays: streak)
    }

    public nonisolated static func buildReport(
        records: [DailyBookListeningRecord],
        period: ListeningStatsPeriod,
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> ListeningPeriodReport {
        let todayKey = dayKey(for: referenceDate, calendar: calendar)
        var secondsByDay: [String: Double] = [:]
        for rec in records where rec.seconds > 0 {
            secondsByDay[rec.dayKey, default: 0] += rec.seconds
        }
        let todaySec = secondsByDay[todayKey] ?? 0
        let streak = computeStreakDays(secondsByDay: secondsByDay, referenceDate: referenceDate, calendar: calendar)

        let periodDates: [Date]
        let dayLabels: [String]
        let allowedDayKeys: Set<String>?

        switch period {
        case .week:
            periodDates = currentWeekDates(around: referenceDate, calendar: calendar)
            dayLabels = ["一", "二", "三", "四", "五", "六", "日"]
            allowedDayKeys = Set(periodDates.map { dayKey(for: $0, calendar: calendar) })
        case .month:
            periodDates = recentDates(count: 14, endingAt: referenceDate, calendar: calendar)
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.dateFormat = "d"
            dayLabels = periodDates.map { formatter.string(from: $0) }
            let monthRange = recentDates(count: 30, endingAt: referenceDate, calendar: calendar)
            allowedDayKeys = Set(monthRange.map { dayKey(for: $0, calendar: calendar) })
        case .all:
            periodDates = currentWeekDates(around: referenceDate, calendar: calendar)
            dayLabels = ["一", "二", "三", "四", "五", "六", "日"]
            allowedDayKeys = nil
        }

        let scopedRecords: [DailyBookListeningRecord]
        if let allowed = allowedDayKeys {
            scopedRecords = records.filter { allowed.contains($0.dayKey) && $0.seconds > 0 }
        } else {
            scopedRecords = records.filter { $0.seconds > 0 }
        }

        let totalSec = scopedRecords.reduce(0.0) { $0 + $1.seconds }
        let activeDaysInScope = Set(scopedRecords.map(\.dayKey)).count
        let avgSec = activeDaysInScope > 0 ? totalSec / Double(activeDaysInScope) : 0

        let barSeconds = periodDates.map { secondsByDay[dayKey(for: $0, calendar: calendar)] ?? 0 }
        let barAvg = barSeconds.filter { $0 > 0 }.isEmpty
            ? 0
            : barSeconds.reduce(0, +) / Double(max(1, barSeconds.filter { $0 > 0 }.count))

        var bars: [ListeningDayBar] = []
        for idx in periodDates.indices {
            let key = dayKey(for: periodDates[idx], calendar: calendar)
            let sec = barSeconds[idx]
            bars.append(
                ListeningDayBar(
                    id: key,
                    label: idx < dayLabels.count ? dayLabels[idx] : "",
                    seconds: sec,
                    isToday: key == todayKey,
                    isAboveAverage: sec > 0 && sec >= barAvg
                )
            )
        }

        var bookTotals: [String: (rec: DailyBookListeningRecord, total: Double)] = [:]
        for rec in scopedRecords {
            if var entry = bookTotals[rec.bookID] {
                entry.total += rec.seconds
                if entry.rec.coverURL.isEmpty && !rec.coverURL.isEmpty { entry.rec = rec }
                bookTotals[rec.bookID] = entry
            } else {
                bookTotals[rec.bookID] = (rec, rec.seconds)
            }
        }
        let sortedBooks = bookTotals.values.sorted { $0.total > $1.total }.prefix(5)
        let maxBookSec = sortedBooks.first?.total ?? 1
        let topBooks = sortedBooks.map { entry in
            ListeningBookRankItem(
                bookID: entry.rec.bookID,
                bookTitle: entry.rec.bookTitle,
                coverURL: entry.rec.coverURL,
                sourceID: entry.rec.sourceID,
                bookURL: entry.rec.bookURL,
                seconds: entry.total,
                ratio: maxBookSec > 0 ? min(1.0, max(0.06, entry.total / maxBookSec)) : 0
            )
        }

        return ListeningPeriodReport(
            period: period,
            totalSeconds: totalSec,
            todaySeconds: todaySec,
            dailyAverageSeconds: avgSec,
            streakDays: streak,
            dailyBars: bars,
            topBooks: topBooks
        )
    }

    public nonisolated static func formatCompactDuration(_ seconds: Double) -> (value: String, unit: String) {
        let safe = seconds.isFinite ? max(0, seconds) : 0
        if safe >= 3600 {
            let hours = safe / 3600.0
            let formatted = hours >= 100 ? String(format: "%.0f", hours) : String(format: "%.1f", hours)
            return (formatted, "小时")
        }
        let minutes = Int((safe / 60.0).rounded())
        return ("\(minutes)", "分钟")
    }

    public nonisolated static func formatInlineDuration(_ seconds: Double) -> String {
        let pair = formatCompactDuration(seconds)
        return "\(pair.value) \(pair.unit)"
    }

    private nonisolated static func currentWeekDates(around referenceDate: Date, calendar: Calendar) -> [Date] {
        let startOfDay = calendar.startOfDay(for: referenceDate)
        let weekday = calendar.component(.weekday, from: startOfDay) // 1=Sun, 2=Mon...
        let offsetFromMonday = (weekday + 5) % 7
        guard let monday = calendar.date(byAdding: .day, value: -offsetFromMonday, to: startOfDay) else {
            return [startOfDay]
        }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: monday) }
    }

    private nonisolated static func recentDates(count: Int, endingAt referenceDate: Date, calendar: Calendar) -> [Date] {
        let startOfDay = calendar.startOfDay(for: referenceDate)
        return (0..<count).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: startOfDay) }
    }

    private nonisolated static func computeStreakDays(
        secondsByDay: [String: Double],
        referenceDate: Date,
        calendar: Calendar
    ) -> Int {
        let startOfToday = calendar.startOfDay(for: referenceDate)
        let todayKey = dayKey(for: startOfToday, calendar: calendar)
        var cursor: Date
        if (secondsByDay[todayKey] ?? 0) > 0 {
            cursor = startOfToday
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday),
                  (secondsByDay[dayKey(for: yesterday, calendar: calendar)] ?? 0) > 0 {
            cursor = yesterday
        } else {
            return 0
        }

        var streak = 0
        while streak < 3650 {
            let key = dayKey(for: cursor, calendar: calendar)
            guard (secondsByDay[key] ?? 0) > 0 else { break }
            streak += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return streak
    }
}
