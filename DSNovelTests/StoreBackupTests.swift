import XCTest
@testable import DSNovel

final class StoreBackupTests: XCTestCase {

    func testBackupCopiesStoreWalShmAndRetainsLatestTwo() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("StoreBackupTests_\(UUID().uuidString)", isDirectory: true)
        let storeDir = tempRoot.appendingPathComponent("Store", isDirectory: true)
        let backupsDir = tempRoot.appendingPathComponent("Backups", isDirectory: true)
        try fm.createDirectory(at: storeDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        for name in ["default.store", "default.store-wal", "default.store-shm"] {
            try Data(name.utf8).write(to: storeDir.appendingPathComponent(name))
        }

        let b1 = try XCTUnwrap(StoreBackup.backupCurrentStore(
            storeDirectory: storeDir,
            backupsRoot: backupsDir,
            maxRetainedCount: 2,
            now: Date(timeIntervalSince1970: 1_700_000_100)
        ))
        XCTAssertTrue(fm.fileExists(atPath: b1.appendingPathComponent("default.store").path))
        XCTAssertTrue(fm.fileExists(atPath: b1.appendingPathComponent("default.store-wal").path))
        XCTAssertTrue(fm.fileExists(atPath: b1.appendingPathComponent("default.store-shm").path))

        _ = try StoreBackup.backupCurrentStore(
            storeDirectory: storeDir,
            backupsRoot: backupsDir,
            maxRetainedCount: 2,
            now: Date(timeIntervalSince1970: 1_700_000_200)
        )
        let b3 = try XCTUnwrap(StoreBackup.backupCurrentStore(
            storeDirectory: storeDir,
            backupsRoot: backupsDir,
            maxRetainedCount: 2,
            now: Date(timeIntervalSince1970: 1_700_000_300)
        ))

        let retained = try fm.contentsOfDirectory(at: backupsDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(retained.count, 2)
        XCTAssertFalse(retained.contains(b1))
        XCTAssertTrue(retained.contains(b3))
    }

    func testBackupWhenStoreEmptyReturnsNil() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("StoreBackupEmpty_\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let result = try StoreBackup.backupCurrentStore(
            storeDirectory: tempRoot.appendingPathComponent("MissingStore"),
            backupsRoot: tempRoot.appendingPathComponent("Backups")
        )
        XCTAssertNil(result)
    }
}
