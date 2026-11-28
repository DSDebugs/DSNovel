import DSCore
import DSDesignSystem
import Foundation
import XCTest
@testable import DSNovel

final class DSSourceHealthCheckTests: XCTestCase {
    @MainActor
    func testBatchCheckSeparatesAvailableInvalidAndNeedsLoginAndPersists() async {
        let suiteName = "DSSourceHealthCheckTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let s1 = SourceMetaDTO(id: "s1", name: "正常源", version: "1", author: "t", summary: "", methods: ["search"])
        let s2 = SourceMetaDTO(id: "s2", name: "失效源", version: "1", author: "t", summary: "", methods: ["search"])
        let s3 = SourceMetaDTO(
            id: "s3",
            name: "未登录源",
            version: "1",
            author: "t",
            summary: "",
            methods: ["search", "checkLogin"],
            loginURL: "https://example.com/login"
        )

        let engine = SourceHealthCheckEngine(defaults: defaults)
        engine.startBatchCheck(sources: [s1, s2, s3], loggedInSourceIDs: []) { meta in
            if meta.id == "s1" {
                return SourceHealthRecord(state: .available, latencyMs: 120, reason: nil, checkedAt: Date())
            }
            return SourceHealthRecord(state: .invalid, latencyMs: nil, reason: "超时", checkedAt: Date())
        }

        // 等待异步批量检测完成
        for _ in 0..<40 where engine.isRunning {
            try? await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(engine.availableCount(in: [s1, s2, s3]), 1)
        XCTAssertEqual(engine.invalidCount(in: [s1, s2, s3]), 1)
        XCTAssertEqual(engine.invalidSourceIDs, ["s2"])
        XCTAssertEqual(engine.record(for: "s3")?.state, .needsLogin)

        // 验证 SourceListFilter.invalid 筛选与计数
        let chips = SourceListHelper.makeFilterChips(
            from: [s1, s2, s3],
            loggedInSourceIDs: [],
            invalidSourceIDs: engine.invalidSourceIDs
        )
        XCTAssertEqual(chips.first(where: { $0.id == SourceListFilter.invalid })?.count, 1)
        let part = SourceListHelper.partition(
            sources: [s1, s2, s3],
            filter: .invalid,
            loggedInSourceIDs: [],
            invalidSourceIDs: engine.invalidSourceIDs
        )
        XCTAssertEqual(part.grouped.flatMap(\SourceGroupSection.sources).map(\SourceMetaDTO.id), ["s2"])

        // 验证持久化重载
        let reloaded = SourceHealthCheckEngine(defaults: defaults)
        XCTAssertEqual(reloaded.invalidSourceIDs, ["s2"])
        XCTAssertEqual(reloaded.record(for: "s1")?.latencyMs, 120)
    }

    func testErrorClassificationDoesNotMisclassifyLoginAsInvalid() {
        let loginErr = NSError(domain: "test", code: 401, userInfo: [NSLocalizedDescriptionKey: "请先登录账号"])
        let (loginState, _) = SourceHealthCheckEngine.classifyError(loginErr)
        XCTAssertEqual(loginState, .needsLogin)

        let timeoutErr = URLError(.timedOut)
        let (timeoutState, timeoutReason) = SourceHealthCheckEngine.classifyError(timeoutErr)
        XCTAssertEqual(timeoutState, .invalid)
        XCTAssertEqual(timeoutReason, "超时")
    }
}
