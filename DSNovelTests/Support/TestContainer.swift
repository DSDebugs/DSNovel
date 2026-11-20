import Foundation
import SwiftData
@testable import DSNovel

enum TestContainer {
    static var schema: Schema {
        Schema([
            Book.self,
            ChapterProgress.self,
            ShelfCategory.self,
            DownloadItem.self,
            PluginRecord.self,
            PluginGroup.self,
            SearchHistory.self,
            BuiltinParserRecord.self
        ])
    }

    @MainActor
    static func make() throws -> ModelContainer {
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }
}
