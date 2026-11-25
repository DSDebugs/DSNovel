import Foundation
import SwiftData

/// 存储引擎启动结果（零 try!、零 fatalError，损坏时安全降级并导向 DataRepairView）
public struct StorageBootstrapResult: @unchecked Sendable {
    public let container: ModelContainer
    public let storeURL: URL
    public let isDegradedInMemory: Bool
    public let startupErrorDescription: String?

    public init(
        container: ModelContainer,
        storeURL: URL,
        isDegradedInMemory: Bool,
        startupErrorDescription: String?
    ) {
        self.container = container
        self.storeURL = storeURL
        self.isDegradedInMemory = isDegradedInMemory
        self.startupErrorDescription = startupErrorDescription
    }
}

/// 同步幂等 SwiftData v3 容器工厂（L-IOS-2 / AUD-41：绑定 DSNovelSchemaV1 与 DSNovelMigrationPlan）
public enum StorageContainerFactory {
    public static let schema = Schema(versionedSchema: DSNovelSchemaV1.self)

    public static func defaultStorageDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("DSNovelV3", isDirectory: true)
    }

    public static func makePersistent(baseDirectory: URL? = nil) throws -> StorageBootstrapResult {
        let dir = baseDirectory ?? defaultStorageDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("DSNovelV3.store")

        let config = ModelConfiguration(
            "DSNovelV3",
            schema: schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        do {
            let container = try ModelContainer(
                for: schema,
                migrationPlan: DSNovelMigrationPlan.self,
                configurations: [config]
            )
            return StorageBootstrapResult(
                container: container,
                storeURL: storeURL,
                isDegradedInMemory: false,
                startupErrorDescription: nil
            )
        } catch {
            let fallbackContainer = try makeInMemory()
            return StorageBootstrapResult(
                container: fallbackContainer,
                storeURL: storeURL,
                isDegradedInMemory: true,
                startupErrorDescription: error.localizedDescription
            )
        }
    }

    public static func makeInMemory() throws -> ModelContainer {
        let config = ModelConfiguration(
            "DSNovelV3Memory-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: DSNovelMigrationPlan.self,
            configurations: [config]
        )
    }
}
