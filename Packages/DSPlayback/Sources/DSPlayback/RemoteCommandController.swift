import AVFoundation
import DSCore
import Foundation
import MediaPlayer
import os

private final class NotificationObserverHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []

    func replace(with next: [NSObjectProtocol]) {
        let old = lock.withLock { () -> [NSObjectProtocol] in
            let prev = tokens
            tokens = next
            return prev
        }
        for token in old {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func removeAll() {
        replace(with: [])
    }

    deinit {
        let old = lock.withLock { () -> [NSObjectProtocol] in
            let prev = tokens
            tokens = []
            return prev
        }
        for token in old {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

/// 锁屏媒体中心、线控、耳机拔出、电话中断/恢复与媒体服务重置控制器
@MainActor
public final class RemoteCommandController {
    private static let logger = Logger(subsystem: "com.dsnovel.v3", category: "AudioSession")
    private let observerHolder = NotificationObserverHolder()
    private var isAudioSessionConfigured = false

    public init() {}

    @discardableResult
    nonisolated private static func bindRemoteCommand(
        _ command: MPRemoteCommand,
        handler: @escaping @MainActor @Sendable () -> MPRemoteCommandHandlerStatus
    ) -> Any {
        command.addTarget { _ in
            Task { @MainActor in
                _ = handler()
            }
            return .success
        }
    }

    @discardableResult
    nonisolated private static func bindPlaybackPositionCommand(
        _ command: MPChangePlaybackPositionCommand,
        handler: @escaping @MainActor @Sendable (Double) -> MPRemoteCommandHandlerStatus
    ) -> Any {
        command.addTarget { event in
            guard let posEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let positionTime = posEvent.positionTime
            Task { @MainActor in
                _ = handler(positionTime)
            }
            return .success
        }
    }

    public func configureAudioSession(force: Bool = false, onError: ((Error) -> Void)? = nil) {
        if isAudioSessionConfigured && !force { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
            isAudioSessionConfigured = true
        } catch {
            isAudioSessionConfigured = false
            Self.logger.error("AVAudioSession 配置失败: \(error.localizedDescription, privacy: .public)")
            onError?(error)
        }
    }

    public func tearDown() {
        observerHolder.removeAll()

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        isAudioSessionConfigured = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    public func installHandlers(
        onPlay: @escaping @MainActor () -> Void,
        onPause: @escaping @MainActor () -> Void,
        onTogglePlayPause: @escaping @MainActor () -> Void,
        onNextChapter: @escaping @MainActor () -> Void,
        onPreviousChapter: @escaping @MainActor () -> Void,
        onSeek: @escaping @MainActor (Double) -> Void,
        onInterruptBegan: @escaping @MainActor () -> Void,
        onInterruptEndedShouldResume: @escaping @MainActor () -> Void,
        onInterruptEndedWithoutResume: (@MainActor () -> Void)? = nil,
        onRouteUnplugged: @escaping @MainActor () -> Void,
        onMediaServicesReset: (@MainActor () -> Void)? = nil
    ) {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)

        Self.bindRemoteCommand(center.playCommand) {
            onPlay()
            return .success
        }
        Self.bindRemoteCommand(center.pauseCommand) {
            onPause()
            return .success
        }
        Self.bindRemoteCommand(center.togglePlayPauseCommand) {
            onTogglePlayPause()
            return .success
        }
        Self.bindRemoteCommand(center.nextTrackCommand) {
            onNextChapter()
            return .success
        }
        Self.bindRemoteCommand(center.previousTrackCommand) {
            onPreviousChapter()
            return .success
        }
        Self.bindPlaybackPositionCommand(center.changePlaybackPositionCommand) { positionTime in
            onSeek(positionTime)
            return .success
        }

        let nc = NotificationCenter.default
        let interruptionToken = nc.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let typeRaw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue,
                  let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else {
                return
            }
            switch type {
            case .began:
                Task { @MainActor [weak self] in
                    self?.isAudioSessionConfigured = false
                    onInterruptBegan()
                }
            case .ended:
                let optRaw = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: optRaw)
                if options.contains(.shouldResume) {
                    Task { @MainActor in onInterruptEndedShouldResume() }
                } else if let onInterruptEndedWithoutResume {
                    Task { @MainActor in onInterruptEndedWithoutResume() }
                }
            @unknown default:
                break
            }
        }

        let routeChangeToken = nc.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let reasonRaw = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else {
                return
            }
            if reason == .oldDeviceUnavailable {
                Task { @MainActor in onRouteUnplugged() }
            }
        }

        let mediaResetToken = nc.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.configureAudioSession(force: true)
                onMediaServicesReset?()
            }
        }

        observerHolder.replace(with: [interruptionToken, routeChangeToken, mediaResetToken])
    }

    public func updateNowPlaying(
        bookTitle: String,
        chapterTitle: String,
        narrator: String,
        elapsed: Double,
        duration: Double,
        rate: Double,
        isPlaying: Bool
    ) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: chapterTitle,
            MPMediaItemPropertyAlbumTitle: bookTitle,
            MPMediaItemPropertyArtist: narrator.isEmpty ? "DSNovel" : narrator,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPMediaItemPropertyPlaybackDuration: max(0, duration),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0.0
        ]
        if duration <= 0 {
            info.removeValue(forKey: MPMediaItemPropertyPlaybackDuration)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
