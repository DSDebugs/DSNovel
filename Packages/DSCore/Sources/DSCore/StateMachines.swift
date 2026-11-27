import Foundation

/// 强类型播放状态机（L-IOS-3：显式携带 shouldPlayWhenReady 与单调代际 generation，彻底消除缓冲态意外外放）
public enum PlaybackState: Sendable, Equatable {
    case idle
    case buffering(generation: UInt64, shouldPlayWhenReady: Bool)
    case playing(generation: UInt64)
    case paused(generation: UInt64)
    case ended(generation: UInt64)
    case failed(generation: UInt64, message: String)

    public var generation: UInt64 {
        switch self {
        case .idle:
            return 0
        case .buffering(let gen, _),
             .playing(let gen),
             .paused(let gen),
             .ended(let gen),
             .failed(let gen, _):
            return gen
        }
    }

    public var isPlaying: Bool {
        if case .playing = self { return true }
        return false
    }

    public var isBuffering: Bool {
        if case .buffering = self { return true }
        return false
    }

    public var shouldPlayWhenReady: Bool {
        switch self {
        case .buffering(_, let flag): return flag
        case .playing: return true
        default: return false
        }
    }

    /// 处理暂停/中断/拔耳机事件：缓冲期内立刻清除自动起播意图
    public func applyingPauseOrInterrupt() -> PlaybackState {
        switch self {
        case .idle, .ended, .failed:
            return self
        case .buffering(let gen, _):
            return .buffering(generation: gen, shouldPlayWhenReady: false)
        case .playing(let gen), .paused(let gen):
            return .paused(generation: gen)
        }
    }

    /// 处理底层 AVPlayerItem 变为 readyToPlay：仅当代际匹配且允许起播时转入 playing
    public func applyingReadyToPlay(for incomingGeneration: UInt64) -> PlaybackState {
        guard incomingGeneration == generation else { return self }
        switch self {
        case .buffering(let gen, let shouldPlay):
            return shouldPlay ? .playing(generation: gen) : .paused(generation: gen)
        default:
            return self
        }
    }

    /// 处理用户主动点击播放
    public func applyingResume() -> PlaybackState {
        switch self {
        case .buffering(let gen, _):
            return .buffering(generation: gen, shouldPlayWhenReady: true)
        case .paused(let gen), .ended(let gen):
            return .playing(generation: gen)
        default:
            return self
        }
    }
}

/// 下载任务池类型（L-IOS-2：manual 与 precache 双池隔离，防 20+ precache 饿死手动下载）
public enum DownloadKind: String, Codable, Sendable, Equatable {
    case manual
    case precache
}

/// 强类型下载状态机（带显式合法流转校验）
public enum DownloadState: String, Codable, Sendable, Equatable, CaseIterable {
    case queued
    case resolving
    case downloading
    case paused
    case completed
    case failed
    case cancelled

    public var isTerminal: Bool {
        self == .completed
    }

    public var isActive: Bool {
        switch self {
        case .resolving, .downloading: return true
        default: return false
        }
    }

    /// 校验状态流转是否合法，杜绝异步竞态把已取消/已完成任务回写为进行中
    public func canTransition(to next: DownloadState) -> Bool {
        if case .completed = self { return false }
        if self == next { return true }
        switch self {
        case .queued:
            return [.resolving, .completed, .paused, .failed, .cancelled].contains(next)
        case .resolving:
            return [.downloading, .paused, .failed, .cancelled, .queued].contains(next)
        case .downloading:
            return [.completed, .paused, .failed, .cancelled, .queued].contains(next)
        case .paused:
            return [.queued, .resolving, .cancelled].contains(next)
        case .failed:
            return [.queued, .cancelled].contains(next)
        case .completed:
            return false
        case .cancelled:
            return [.queued].contains(next)
        }
    }
}

/// 指数退避策略计算器（L-IOS-2：2s / 6s / 14s，429/503 加倍，最大 3 次重试）
public struct DownloadRetryPolicy: Sendable, Equatable {
    public static let maxRetries = 3

    public static func delaySeconds(retryCount: Int, httpStatus: Int?) -> TimeInterval? {
        guard retryCount >= 0, retryCount < maxRetries else { return nil }
        let base: TimeInterval = (retryCount == 0) ? 2.0 : (retryCount == 1 ? 6.0 : 14.0)
        let isThrottled = (httpStatus == 429 || httpStatus == 503)
        return isThrottled ? base * 2.0 : base
    }

    /// 鉴权失效或资源过期状态码：必须作废旧 resumeData 重新解析
    public static func shouldInvalidateResumeData(httpStatus: Int?) -> Bool {
        guard let code = httpStatus else { return false }
        return code == 401 || code == 403 || code == 410 || code == 416
    }
}
