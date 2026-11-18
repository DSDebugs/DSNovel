import Foundation
import SwiftData

@MainActor
enum DownloadsDataHelper {
    static func partitionItems(_ items: [DownloadItem]) -> (active: [DownloadItem], failed: [DownloadItem]) {
        let active = items.filter {
            $0.state == "downloading" || $0.state == "queued" || $0.state == "waitingWiFi" || $0.state == "paused"
        }
        let failed = items.filter { $0.state == "failed" }
        return (active, failed)
    }

    static func partitionItemsForBook(_ bookID: String?, from items: [DownloadItem]) -> (active: [DownloadItem], failed: [DownloadItem], completed: [DownloadItem]) {
        guard let bookID, !bookID.isEmpty else { return ([], [], []) }
        let bookItems = items.filter { $0.bookID == bookID }
        let active = bookItems.filter {
            $0.state == "downloading" || $0.state == "queued" || $0.state == "waitingWiFi" || $0.state == "paused"
        }
        let failed = bookItems.filter { $0.state == "failed" }
        let completed = bookItems.filter { $0.state == "completed" }
        return (active, failed, completed)
    }

    static func sortedSummaries(_ map: [String: DownloadSummary]) -> [DownloadSummary] {
        map.values.filter { $0.completedCount > 0 }.sorted { $0.bookTitle < $1.bookTitle }
    }

    static func itemsForBook(_ bookID: String, from items: [DownloadItem]) -> [DownloadItem] {
        items.filter { $0.bookID == bookID && $0.state == "completed" }
    }
}
