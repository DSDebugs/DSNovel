import DSCore
import DSPluginKit
import Foundation
import Observation

/// 书源账号登录态枚举
enum SourceAuthStatus: Equatable, Sendable {
    case unknown
    case checking
    case loggedIn(nickname: String)
    case loggedOut(reason: String?)

    var isLoggedIn: Bool {
        if case .loggedIn = self { return true }
        return false
    }

    var isChecking: Bool {
        if case .checking = self { return true }
        return false
    }
}

/// 全局书源登录态缓存（供书源管理列表、书源详情页与网页登录页同步状态；瞬态失败 30 秒后允许静默重检）
@Observable
@MainActor
final class SourceAuthStateStore {
    private static let failedRetryTTL: TimeInterval = 30

    private(set) var statuses: [String: SourceAuthStatus] = [:]
    private var inFlightTasks: [String: Task<SourceAuthStatus, Never>] = [:]
    private var lastFailedCheckAt: [String: Date] = [:]
    private var manuallyLoggedOutIDs: Set<String> = []

    func status(for sourceID: String) -> SourceAuthStatus {
        statuses[sourceID] ?? .unknown
    }

    func isLoggedIn(_ sourceID: String) -> Bool {
        status(for: sourceID).isLoggedIn
    }

    var loggedInSourceIDs: Set<String> {
        var ids = Set<String>()
        for (id, st) in statuses where st.isLoggedIn {
            ids.insert(id)
        }
        return ids
    }

    /// 主动退出登录或清除 Cookie 时立即标记为未登录（不再自动静默重检，直到用户重新登录或手动检测）
    func markLoggedOut(sourceID: String, reason: String? = "未登录或已退出") {
        inFlightTasks[sourceID]?.cancel()
        inFlightTasks.removeValue(forKey: sourceID)
        lastFailedCheckAt.removeValue(forKey: sourceID)
        manuallyLoggedOutIDs.insert(sourceID)
        statuses[sourceID] = .loggedOut(reason: reason)
    }

    /// 检测单个书源的真实登录态；默认复用进行中的检测任务，force=true 时强制重新校验
    @discardableResult
    func refresh(
        sourceID: String,
        runtime: PluginRuntime,
        force: Bool = false
    ) async -> SourceAuthStatus {
        if !force {
            if let existing = inFlightTasks[sourceID] {
                return await existing.value
            }
            if case .loggedIn = statuses[sourceID] {
                return statuses[sourceID] ?? .unknown
            }
        } else {
            inFlightTasks[sourceID]?.cancel()
            inFlightTasks.removeValue(forKey: sourceID)
            manuallyLoggedOutIDs.remove(sourceID)
        }

        statuses[sourceID] = .checking
        let task = Task<SourceAuthStatus, Never> { @MainActor [weak self] in
            let next: SourceAuthStatus
            let didFailCheck: Bool
            do {
                let nickname = try await runtime.checkLogin(sourceID: sourceID)
                let clean = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
                next = .loggedIn(nickname: clean)
                didFailCheck = false
            } catch is CancellationError {
                return self?.statuses[sourceID] ?? .unknown
            } catch {
                next = .loggedOut(reason: error.localizedDescription)
                didFailCheck = true
            }
            if !Task.isCancelled {
                self?.statuses[sourceID] = next
                self?.inFlightTasks.removeValue(forKey: sourceID)
                if didFailCheck {
                    self?.lastFailedCheckAt[sourceID] = Date()
                } else {
                    self?.lastFailedCheckAt.removeValue(forKey: sourceID)
                    self?.manuallyLoggedOutIDs.remove(sourceID)
                }
            }
            return next
        }
        inFlightTasks[sourceID] = task
        return await task.value
    }

    /// 批量静默刷新所有支持登录的书源状态（已登录或主动退出的跳过；瞬态失败超过 30 秒后自动重检）
    func refreshAllLoginCapable(
        sources: [SourceMetaDTO],
        runtime: PluginRuntime,
        force: Bool = false
    ) async {
        let targets = sources.filter { $0.loginURL != nil || $0.methods.contains("checkLogin") }
        guard !targets.isEmpty else { return }
        let now = Date()
        var toCheck: [String] = []
        for src in targets {
            if !force {
                let current = statuses[src.id] ?? .unknown
                if current.isLoggedIn || current.isChecking { continue }
                if manuallyLoggedOutIDs.contains(src.id) { continue }
                if case .loggedOut = current,
                   let failedAt = lastFailedCheckAt[src.id],
                   now.timeIntervalSince(failedAt) < Self.failedRetryTTL {
                    continue
                }
            }
            toCheck.append(src.id)
        }
        guard !toCheck.isEmpty else { return }
        for sourceID in toCheck {
            _ = await refresh(sourceID: sourceID, runtime: runtime, force: force)
        }
    }
}
