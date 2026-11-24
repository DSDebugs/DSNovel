import AVFoundation
import DSCore
import Foundation
import MediaPlayer
import os
import UIKit

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
    private struct NowPlayingSnapshot {
        let bookTitle: String
        let chapterTitle: String
        let narrator: String
        let coverURL: String
        let elapsed: Double
        let duration: Double
        let rate: Double
        let isPlaying: Bool
        let chapterNumber: Int?
        let chapterCount: Int?
    }

    private let observerHolder = NotificationObserverHolder()
    private var isAudioSessionConfigured = false
    private var cachedArtworkURL: String = ""
    private var cachedArtwork: MPMediaItemArtwork?
    private var inFlightArtworkURL: String?
    private var artworkLoadTask: Task<Void, Never>?
    private var lastSnapshot: NowPlayingSnapshot?
    private lazy var fallbackArtwork: MPMediaItemArtwork? = {
        guard let img = UIImage(named: "AppIconPreview") else { return nil }
        return Self.makeArtwork(from: img)
    }()

    public init() {}

    nonisolated private static func makeArtwork(from image: UIImage) -> MPMediaItemArtwork {
        let size = (image.size.width > 0 && image.size.height > 0) ? image.size : CGSize(width: 300, height: 300)
        return MPMediaItemArtwork(boundsSize: size) { _ in image }
    }

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
        artworkLoadTask?.cancel()
        artworkLoadTask = nil
        inFlightArtworkURL = nil
        cachedArtworkURL = ""
        cachedArtwork = nil
        lastSnapshot = nil

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
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
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true

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
        coverURL: String = "",
        artworkImage: UIImage? = nil,
        elapsed: Double,
        duration: Double,
        rate: Double,
        isPlaying: Bool,
        canPrevious: Bool = true,
        canNext: Bool = true,
        chapterNumber: Int? = nil,
        chapterCount: Int? = nil
    ) {
        let trimmedURL = coverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let artworkImage, !trimmedURL.isEmpty {
            cachedArtworkURL = trimmedURL
            cachedArtwork = Self.makeArtwork(from: artworkImage)
        } else if trimmedURL != cachedArtworkURL {
            cachedArtworkURL = ""
            cachedArtwork = nil
        }

        let snapshot = NowPlayingSnapshot(
            bookTitle: bookTitle,
            chapterTitle: chapterTitle,
            narrator: narrator,
            coverURL: trimmedURL,
            elapsed: elapsed,
            duration: duration,
            rate: rate,
            isPlaying: isPlaying,
            chapterNumber: chapterNumber,
            chapterCount: chapterCount
        )
        lastSnapshot = snapshot

        let center = MPRemoteCommandCenter.shared()
        center.previousTrackCommand.isEnabled = canPrevious
        center.nextTrackCommand.isEnabled = canNext
        publishNowPlaying(snapshot)
    }

    public func ensureArtworkLoaded(
        for coverURL: String,
        syncLookup: ((String) -> UIImage?)?,
        asyncLoader: (@MainActor (String) async -> UIImage?)?
    ) {
        let trimmed = coverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            artworkLoadTask?.cancel()
            artworkLoadTask = nil
            inFlightArtworkURL = nil
            return
        }
        if (cachedArtworkURL == trimmed && cachedArtwork != nil) || inFlightArtworkURL == trimmed { return }
        if let img = syncLookup?(trimmed) {
            cachedArtworkURL = trimmed
            cachedArtwork = Self.makeArtwork(from: img)
            applyArtworkInPlace(cachedArtwork, forURL: trimmed)
            return
        }
        guard let asyncLoader else { return }
        artworkLoadTask?.cancel()
        inFlightArtworkURL = trimmed
        artworkLoadTask = Task { @MainActor [weak self] in
            let loaded = await asyncLoader(trimmed)
            guard let self else { return }
            if self.inFlightArtworkURL == trimmed { self.inFlightArtworkURL = nil }
            guard !Task.isCancelled, let loaded else { return }
            self.cachedArtworkURL = trimmed
            self.cachedArtwork = Self.makeArtwork(from: loaded)
            self.applyArtworkInPlace(self.cachedArtwork, forURL: trimmed)
        }
    }

    private func applyArtworkInPlace(_ artwork: MPMediaItemArtwork?, forURL url: String) {
        guard let artwork, lastSnapshot?.coverURL == url else { return }
        let center = MPNowPlayingInfoCenter.default()
        if var info = center.nowPlayingInfo {
            info[MPMediaItemPropertyArtwork] = artwork
            center.nowPlayingInfo = info
        }
    }

    private func publishNowPlaying(_ snapshot: NowPlayingSnapshot) {
        let cleanBook = snapshot.bookTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNarrator = snapshot.narrator.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayArtist: String
        if !cleanBook.isEmpty && !cleanNarrator.isEmpty && cleanBook != cleanNarrator {
            displayArtist = "\(cleanBook) · \(cleanNarrator)"
        } else if !cleanBook.isEmpty {
            displayArtist = cleanBook
        } else if !cleanNarrator.isEmpty {
            displayArtist = cleanNarrator
        } else {
            displayArtist = "DSNovel"
        }

        let safeDuration = snapshot.duration.isFinite ? max(0, snapshot.duration) : 0
        let rawElapsed = snapshot.elapsed.isFinite ? max(0, snapshot.elapsed) : 0
        let safeElapsed = safeDuration > 0 ? min(rawElapsed, safeDuration) : rawElapsed
        let safeRate = (snapshot.rate.isFinite && snapshot.rate > 0) ? snapshot.rate : 1.0

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: snapshot.chapterTitle,
            MPMediaItemPropertyAlbumTitle: cleanBook,
            MPMediaItemPropertyArtist: displayArtist,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: safeElapsed,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: safeRate,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.isPlaying ? safeRate : 0.0
        ]
        if safeDuration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = safeDuration
        }
        if let num = snapshot.chapterNumber, let count = snapshot.chapterCount, count > 0 {
            info[MPNowPlayingInfoPropertyChapterNumber] = max(0, num - 1)
            info[MPNowPlayingInfoPropertyChapterCount] = count
        }
        if let artwork = (cachedArtworkURL == snapshot.coverURL ? cachedArtwork : nil) ?? fallbackArtwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        let nowPlayingCenter = MPNowPlayingInfoCenter.default()
        nowPlayingCenter.nowPlayingInfo = info
        nowPlayingCenter.playbackState = snapshot.isPlaying ? .playing : .paused
    }
}
