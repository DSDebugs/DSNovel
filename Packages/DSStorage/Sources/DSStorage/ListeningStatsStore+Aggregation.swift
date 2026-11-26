import DSCore
import Foundation

/// 听书统计纯函数聚合与格式化扩展
extension ListeningStatsStore {
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
