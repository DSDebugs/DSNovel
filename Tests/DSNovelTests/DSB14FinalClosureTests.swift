import DSCore
import DSStorage
import Foundation
import SQLite3
import XCTest

/// 最终两处轻量收口（b14）回归测试套件（总单测数达 311 项）
final class DSB14FinalClosureTests: XCTestCase {
    // 退后台定期自动备份：首次立即创建，间隔期内幂等跳过，超间隔后再创建
    func testB14_CreateBackupIfNeededRespectsMinInterval() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dsnovel-b14-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let storeURL = dir.appendingPathComponent("test.store")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(storeURL.path, &db), SQLITE_OK)
        defer { if let db { sqlite3_close(db) } }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE t(id INTEGER PRIMARY KEY);", nil, nil, nil), SQLITE_OK)

        let manager = StoreBackupManager(storeURL: storeURL, maxBackups: 5)
        let first = try await manager.createBackupIfNeeded(minIntervalSeconds: 3600)
        XCTAssertNotNil(first)

        let second = try await manager.createBackupIfNeeded(minIntervalSeconds: 3600)
        XCTAssertNil(second)

        let forced = try await manager.createBackupIfNeeded(minIntervalSeconds: 0)
        XCTAssertNotNil(forced)
    }

    // 冷启动首路径等待：测试模式（startImmediately: false）下立即返回零等待
    @MainActor
    func testB14_NetworkMonitorWaitForInitialPathReturnsImmediatelyWhenNotStarted() async {
        let monitor = NetworkReachabilityMonitor(startImmediately: false)
        XCTAssertTrue(monitor.hasReceivedInitialPath)
        await monitor.waitForInitialPath(timeoutSeconds: 0.2)
        XCTAssertTrue(monitor.hasReceivedInitialPath)
    }

    // 模拟切换为蜂窝流量后标记首路径已就绪且 isOnWiFi == false
    @MainActor
    func testB14_NetworkMonitorSimulateCellularUpdatesPolicyState() {
        let monitor = NetworkReachabilityMonitor(startImmediately: false)
        var lastCallback: Bool?
        monitor.setOnNetworkTypeChanged { lastCallback = $0 }
        monitor.simulateState(connected: true, onWiFi: false)
        XCTAssertFalse(monitor.isOnWiFi)
        XCTAssertEqual(lastCallback, false)
    }
}
