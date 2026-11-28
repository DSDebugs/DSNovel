import Foundation
import UIKit

/// 系统导出面板执行结果
enum OfflineAudioExportOutcome: Sendable, Equatable {
    case completed
    case cancelled
    case failed(String)
}

/// 系统导出面板桥接器（规避菜单/弹窗收起同帧抢占，支持原生分享面板与文件夹导出到「文件」）
@MainActor
final class OfflineAudioExportPresenter: NSObject, UIDocumentPickerDelegate {
    private var shareSheetContinuation: CheckedContinuation<OfflineAudioExportOutcome, Never>?
    private var folderExportContinuation: CheckedContinuation<OfflineAudioExportOutcome, Never>?

    override init() {
        super.init()
    }

    /// 拉起系统原生分享面板（支持「存储到“文件”」、隔空投送、微信及第三方播放器）
    func presentShareSheet(urls: [URL]) async -> OfflineAudioExportOutcome {
        guard !urls.isEmpty else { return .failed("暂无可导出的音频文件") }
        try? await Task.sleep(for: .milliseconds(120))
        guard let presenter = Self.topMostViewController() else {
            return .failed("无法打开系统分享面板，请稍后重试")
        }

        if let stale = shareSheetContinuation {
            shareSheetContinuation = nil
            stale.resume(returning: .cancelled)
        }

        return await withCheckedContinuation { continuation in
            self.shareSheetContinuation = continuation
            let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
            if let popover = controller.popoverPresentationController {
                popover.sourceView = presenter.view
                popover.sourceRect = CGRect(
                    x: presenter.view.bounds.midX,
                    y: presenter.view.bounds.midY,
                    width: 1,
                    height: 1
                )
                popover.permittedArrowDirections = []
            }
            controller.completionWithItemsHandler = { _, completed, _, error in
                let errorMessage = error?.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self, let pending = self.shareSheetContinuation else { return }
                    self.shareSheetContinuation = nil
                    if let errorMessage {
                        pending.resume(returning: .failed(errorMessage))
                    } else if completed {
                        pending.resume(returning: .completed)
                    } else {
                        pending.resume(returning: .cancelled)
                    }
                }
            }
            presenter.present(controller, animated: true)
        }
    }

    /// 拉起原生「文件」导出选择器，将整本/批量书名文件夹一次性导出至指定目录
    func presentFolderExport(folderURL: URL) async -> OfflineAudioExportOutcome {
        try? await Task.sleep(for: .milliseconds(120))
        guard let presenter = Self.topMostViewController() else {
            return .failed("无法打开「文件」导出面板，请稍后重试")
        }

        if let stale = folderExportContinuation {
            folderExportContinuation = nil
            stale.resume(returning: .cancelled)
        }

        return await withCheckedContinuation { continuation in
            self.folderExportContinuation = continuation
            let picker = UIDocumentPickerViewController(forExporting: [folderURL], asCopy: true)
            picker.delegate = self
            presenter.present(picker, animated: true)
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let continuation = folderExportContinuation else { return }
        folderExportContinuation = nil
        continuation.resume(returning: .completed)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard let continuation = folderExportContinuation else { return }
        folderExportContinuation = nil
        continuation.resume(returning: .cancelled)
    }

    private static func topMostViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }

        let root = scenes
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
            ?? scenes.first?.windows.first?.rootViewController

        return deepestPresented(from: root)
    }

    private static func deepestPresented(from controller: UIViewController?) -> UIViewController? {
        var current = controller
        while let presented = current?.presentedViewController, !presented.isBeingDismissed {
            current = presented
        }
        return current
    }
}
