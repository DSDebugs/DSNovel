import SwiftUI
import Observation
import UIKit

enum DSBannerKind: Equatable {
    case info
    case success
    case warning
    case error
    case undo

    var defaultDuration: TimeInterval {
        switch self {
        case .info: return 2.5
        case .success: return 2.5
        case .warning: return 4.0
        case .error: return 6.0
        case .undo: return 5.0
        }
    }

    var iconName: String {
        switch self {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .undo: return "arrow.uturn.backward.circle.fill"
        }
    }
}

struct DSBannerItem: Identifiable, Equatable {
    let id: UUID
    let message: String
    let kind: DSBannerKind
    let createdAt: TimeInterval
    let duration: TimeInterval

    init(
        id: UUID = UUID(),
        message: String,
        kind: DSBannerKind,
        createdAt: TimeInterval = Date().timeIntervalSince1970,
        duration: TimeInterval? = nil
    ) {
        self.id = id
        self.message = message
        self.kind = kind
        self.createdAt = createdAt
        self.duration = duration ?? kind.defaultDuration
    }
}

@MainActor
@Observable
final class BannerCenter {
    static let shared = BannerCenter()

    private(set) var currentBanner: DSBannerItem?
    private var activeCommitCallback: (() -> Void)?
    private var activeUndoCallback: (() -> Void)?
    private var hasResolvedUndo = false
    private var recentMessages: [String: TimeInterval] = [:]
    private var autoDismissTask: Task<Void, Never>?

    init() {}

    func show(
        _ message: String,
        kind: DSBannerKind = .info,
        now: TimeInterval = Date().timeIntervalSince1970,
        scheduleAutoDismiss: Bool = true,
        bypassDeduplication: Bool = false
    ) {
        guard !message.isEmpty else { return }
        if !bypassDeduplication, let lastTime = recentMessages[message], (now - lastTime) < 3.0 {
            return
        }
        if let existing = currentBanner, existing.kind == .error && kind != .error && kind != .undo {
            return
        }
        commitActiveUndoIfNeeded()
        recentMessages[message] = now
        let item = DSBannerItem(message: message, kind: kind, createdAt: now)
        currentBanner = item
        UIAccessibility.post(notification: .announcement, argument: message)

        autoDismissTask?.cancel()
        if scheduleAutoDismiss {
            let itemID = item.id
            let delay = item.duration
            autoDismissTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.expireIfMatching(id: itemID)
                }
            }
        }
    }

    func showUndo(
        _ message: String,
        now: TimeInterval = Date().timeIntervalSince1970,
        scheduleAutoDismiss: Bool = true,
        onUndo: @escaping () -> Void,
        onCommit: @escaping () -> Void
    ) {
        commitActiveUndoIfNeeded()
        hasResolvedUndo = false
        activeUndoCallback = onUndo
        activeCommitCallback = onCommit
        recentMessages[message] = now
        let item = DSBannerItem(message: message, kind: .undo, createdAt: now, duration: 5.0)
        currentBanner = item
        UIAccessibility.post(notification: .announcement, argument: message)

        autoDismissTask?.cancel()
        if scheduleAutoDismiss {
            let itemID = item.id
            autoDismissTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5.0))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.expireIfMatching(id: itemID)
                }
            }
        }
    }

    func triggerUndo() {
        guard currentBanner?.kind == .undo, !hasResolvedUndo else { return }
        hasResolvedUndo = true
        autoDismissTask?.cancel()
        let undo = activeUndoCallback
        activeUndoCallback = nil
        activeCommitCallback = nil
        currentBanner = nil
        undo?()
    }

    /// 取消当前未提交的撤销任务且不执行 onCommit（供高频收藏切换直接接管状态时使用）
    func cancelPendingUndoWithoutCommit() {
        guard currentBanner?.kind == .undo, !hasResolvedUndo else { return }
        hasResolvedUndo = true
        autoDismissTask?.cancel()
        activeUndoCallback = nil
        activeCommitCallback = nil
        currentBanner = nil
    }

    func handleDidEnterBackground() {
        commitActiveUndoIfNeeded()
    }

    func dismissCurrent() {
        autoDismissTask?.cancel()
        commitActiveUndoIfNeeded()
        currentBanner = nil
    }

    func expireIfMatching(id: UUID) {
        guard currentBanner?.id == id else { return }
        commitActiveUndoIfNeeded()
        currentBanner = nil
    }

    private func commitActiveUndoIfNeeded() {
        guard !hasResolvedUndo, let commit = activeCommitCallback else {
            activeUndoCallback = nil
            activeCommitCallback = nil
            return
        }
        hasResolvedUndo = true
        activeUndoCallback = nil
        activeCommitCallback = nil
        commit()
    }

    func resetForTesting() {
        autoDismissTask?.cancel()
        currentBanner = nil
        activeCommitCallback = nil
        activeUndoCallback = nil
        hasResolvedUndo = true
        recentMessages.removeAll()
    }
}
