import DSCore
import DSStorage
import Foundation
import Testing

@Suite("DSListeningStats 聚合、连续天数与格式化测试")
struct DSListeningStatsTests {
    private var fixedCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .current
        return cal
    }

    private func makeDate(year: Int, month: Int, day: Int) -> Date {
        let comps = DateComponents(year: year, month: month, day: day, hour: 12)
        return fixedCalendar.date(from: comps) ?? Date(timeIntervalSince1970: 0)
    }

    @Test("computeOverview 准确汇总今日、本周与连续天数")
    func overviewSummaryAndStreak() {
        let cal = fixedCalendar
        let wed = makeDate(year: 2026, month: 11, day: 25) // 周三
        let tue = makeDate(year: 2026, month: 11, day: 24) // 周二
        let mon = makeDate(year: 2026, month: 11, day: 23) // 周一
        let prevSun = makeDate(year: 2026, month: 11, day: 22) // 上周日

        let records = [
            DailyBookListeningRecord(
                dayKey: ListeningStatsStore.dayKey(for: wed, calendar: cal),
                bookID: "b1", bookTitle: "诡秘之主", coverURL: "", sourceID: "s1", bookURL: "u1", seconds: 1800
            ),
            DailyBookListeningRecord(
                dayKey: ListeningStatsStore.dayKey(for: tue, calendar: cal),
                bookID: "b1", bookTitle: "诡秘之主", coverURL: "", sourceID: "s1", bookURL: "u1", seconds: 2400
            ),
            DailyBookListeningRecord(
                dayKey: ListeningStatsStore.dayKey(for: mon, calendar: cal),
                bookID: "b2", bookTitle: "青山", coverURL: "", sourceID: "s2", bookURL: "u2", seconds: 1200
            ),
            DailyBookListeningRecord(
                dayKey: ListeningStatsStore.dayKey(for: prevSun, calendar: cal),
                bookID: "b2", bookTitle: "青山", coverURL: "", sourceID: "s2", bookURL: "u2", seconds: 900
            )
        ]

        let overview = ListeningStatsStore.computeOverview(records: records, referenceDate: wed, calendar: cal)
        #expect(overview.todaySeconds == 1800)
        #expect(overview.weekSeconds == 5400) // 周一+周二+周三（不含上周日）
        #expect(overview.streakDays == 4)     // 周日、周一、周二、周三连续 4 天
    }

    @Test("今日尚未收听但昨日有收听时保留连续天数")
    func streakPreservedFromYesterday() {
        let cal = fixedCalendar
        let today = makeDate(year: 2026, month: 11, day: 25)
        let yesterday = makeDate(year: 2026, month: 11, day: 24)
        let twoDaysAgo = makeDate(year: 2026, month: 11, day: 23)

        let records = [
            DailyBookListeningRecord(
                dayKey: ListeningStatsStore.dayKey(for: yesterday, calendar: cal),
                bookID: "b1", bookTitle: "测试书", coverURL: "", sourceID: "s1", bookURL: "u1", seconds: 600
            ),
            DailyBookListeningRecord(
                dayKey: ListeningStatsStore.dayKey(for: twoDaysAgo, calendar: cal),
                bookID: "b1", bookTitle: "测试书", coverURL: "", sourceID: "s1", bookURL: "u1", seconds: 600
            )
        ]

        let overview = ListeningStatsStore.computeOverview(records: records, referenceDate: today, calendar: cal)
        #expect(overview.todaySeconds == 0)
        #expect(overview.streakDays == 2)
    }

    @Test("buildReport 按周期汇总、输出柱状图与 Top 书籍降序排行")
    func reportRankingAndBars() {
        let cal = fixedCalendar
        let wed = makeDate(year: 2026, month: 11, day: 25)
        let oldDay = makeDate(year: 2026, month: 10, day: 1)

        let records = [
            DailyBookListeningRecord(
                dayKey: ListeningStatsStore.dayKey(for: wed, calendar: cal),
                bookID: "b1", bookTitle: "书A", coverURL: "https://a.jpg", sourceID: "s1", bookURL: "u1", seconds: 3600
            ),
            DailyBookListeningRecord(
                dayKey: ListeningStatsStore.dayKey(for: wed, calendar: cal),
                bookID: "b2", bookTitle: "书B", coverURL: "https://b.jpg", sourceID: "s2", bookURL: "u2", seconds: 1800
            ),
            DailyBookListeningRecord(
                dayKey: ListeningStatsStore.dayKey(for: oldDay, calendar: cal),
                bookID: "b3", bookTitle: "老书C", coverURL: "", sourceID: "s3", bookURL: "u3", seconds: 7200
            )
        ]

        let weekReport = ListeningStatsStore.buildReport(records: records, period: .week, referenceDate: wed, calendar: cal)
        #expect(weekReport.dailyBars.count == 7)
        #expect(weekReport.totalSeconds == 5400)
        #expect(weekReport.topBooks.count == 2)
        #expect(weekReport.topBooks.first?.bookID == "b1")
        #expect(weekReport.topBooks.first?.ratio == 1.0)
        #expect(weekReport.topBooks.last?.bookID == "b2")
        #expect(weekReport.topBooks.last?.ratio == 0.5)

        let allReport = ListeningStatsStore.buildReport(records: records, period: .all, referenceDate: wed, calendar: cal)
        #expect(allReport.totalSeconds == 12600)
        #expect(allReport.topBooks.first?.bookID == "b3")
    }

    @Test("formatCompactDuration 在分钟与小时区间输出正确单位")
    func durationFormatting() {
        let zero = ListeningStatsStore.formatCompactDuration(0)
        #expect(zero.value == "0" && zero.unit == "分钟")

        let mins = ListeningStatsStore.formatCompactDuration(42 * 60)
        #expect(mins.value == "42" && mins.unit == "分钟")

        let hours = ListeningStatsStore.formatCompactDuration(6.5 * 3600)
        #expect(hours.value == "6.5" && hours.unit == "小时")
    }
}
