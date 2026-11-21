import Foundation
import Observation

/// 独立高频下载进度与下载中码率存储（P1：与 DownloadManager.stateVersion 解耦，避免进度更新触发全屏视图树重绘）
@Observable
@MainActor
final class DownloadProgressStore {
    static let shared = DownloadProgressStore()

    var progressByItemID: [String: Double] = [:]
    var bitrateKbpsByItemID: [String: Int] = [:]

    init() {}

    func updateProgress(_ fraction: Double, for itemID: String) {
        progressByItemID[itemID] = fraction
    }

    func removeProgress(for itemID: String) {
        progressByItemID.removeValue(forKey: itemID)
    }

    func updateBitrate(_ kbps: Int, for itemID: String) {
        if bitrateKbpsByItemID[itemID] != kbps {
            bitrateKbpsByItemID[itemID] = kbps
        }
    }

    func removeBitrate(for itemID: String) {
        bitrateKbpsByItemID.removeValue(forKey: itemID)
    }

    func clear(for itemID: String) {
        progressByItemID.removeValue(forKey: itemID)
        bitrateKbpsByItemID.removeValue(forKey: itemID)
    }
}
