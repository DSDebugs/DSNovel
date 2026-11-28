import AVFoundation
import Foundation
import Observation

/// 倍速格式化工具（解决 %.2gx 将 1.25x 截断为 1.2x 的精度缺陷）
public enum PlayerSpeedFormatter {
    public static func format(_ speed: Double) -> String {
        let clamped = min(max(speed, 0.5), 3.0)
        let rounded = (clamped * 100.0).rounded() / 100.0
        let intPart = Int(rounded)
        if abs(rounded - Double(intPart)) < 0.001 {
            return "\(intPart).0x"
        }
        let tenths = (rounded * 10.0).rounded() / 10.0
        if abs(rounded - tenths) < 0.001 {
            return String(format: "%.1fx", rounded)
        }
        return String(format: "%.2fx", rounded)
    }
}

/// 5 段均衡器预设
public enum AudioEQPreset: String, Codable, Sendable, CaseIterable, Identifiable {
    case flat
    case voiceBoost
    case warm
    case night
    case bright

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .flat: return "原声均衡"
        case .voiceBoost: return "人声增强"
        case .warm: return "温暖醇厚"
        case .night: return "夜间助眠"
        case .bright: return "清晰通透"
        }
    }

    public var bandGainsDB: [Float] {
        switch self {
        case .flat: return [0, 0, 0, 0, 0]
        case .voiceBoost: return [-3, -1, 4, 3.5, 0.5]
        case .warm: return [3.5, 1.5, 0, -2, -3.5]
        case .night: return [-3.5, 0.5, 1.5, -2.5, -4.5]
        case .bright: return [-2, -1, 2, 3.5, 3]
        }
    }
}

/// 音效与 DSP 管理器（L-IOS-3：挂载真实 MTAudioProcessingTap + Pre-EQ AI 智能修音 + 代际隔离看门狗）
@Observable
@MainActor
public final class AudioTapDSP {
    public var preset: AudioEQPreset = .flat {
        didSet {
            isApplyingPreset = true
            isCustomEQ = false
            customBands = preset.bandGainsDB
            isApplyingPreset = false
            persistPreferencesIfBound()
            pushParamsToProcessor()
        }
    }
    public var customBands: [Float] = [0, 0, 0, 0, 0] {
        didSet {
            guard !isApplyingPreset else { return }
            isCustomEQ = true
            persistPreferencesIfBound()
            scheduleDebouncedParamPush()
        }
    }
    public var isCustomEQ: Bool = false
    public var stereoBalance: Float = 0.0 {
        didSet { pushParamsToProcessor() }
    }
    public var volumeBoostDB: Float = 0.0 {
        didSet {
            let clamped = volumeBoostDB.isFinite ? min(9.0, max(0.0, volumeBoostDB)) : 0.0
            if abs(volumeBoostDB - clamped) > 0.001 {
                volumeBoostDB = clamped
                return
            }
            persistPreferencesIfBound()
            pushParamsToProcessor()
        }
    }
    public var volumeBoostEnabled: Bool {
        get { volumeBoostDB > 0.05 }
        set { volumeBoostDB = newValue ? 3.0 : 0.0 }
    }
    public var dynamicLevelingEnabled: Bool = false {
        didSet {
            persistPreferencesIfBound()
            pushParamsToProcessor()
        }
    }
    public var smartRepairEnabled: Bool = false {
        didSet {
            if !smartRepairEnabled {
                smartTelemetry = .idle
            }
            persistPreferencesIfBound()
            pushParamsToProcessor()
        }
    }
    public var smartRepairIntensity: AudioSmartIntensity = .standard {
        didSet {
            persistPreferencesIfBound()
            pushParamsToProcessor()
        }
    }
    public private(set) var smartTelemetry: AudioSmartTelemetry = .idle
    public var onParametersUpdated: (@MainActor () -> Void)?

    public var watchdogTimeoutNanoseconds: UInt64
    public private(set) var streamGeneration: UInt64 = 0
    public private(set) var isUsingNativeVolumeFallback: Bool = false
    public private(set) var fallbackReason: String?
    public private(set) var currentFadeGain: Float = 1.0

    public var isWatchdogPending: Bool {
        watchdogTask != nil
    }

    private let processor = AudioTapProcessor()
    private var isApplyingPreset: Bool = false
    private var watchdogTask: Task<Void, Never>?
    private var debouncePushTask: Task<Void, Never>?
    private var tapReceiptReceived: Bool = false
    private var pendingFallbackHandler: (@MainActor () -> Void)?
    private var volumeSyncHandler: (@MainActor () -> Void)?
    private var persistedDefaults: UserDefaults?
    private var isRestoringPreferences: Bool = false

    public init(watchdogTimeoutNanoseconds: UInt64 = 800_000_000) {
        self.watchdogTimeoutNanoseconds = watchdogTimeoutNanoseconds
    }

    public func currentParameters() -> AudioDSPParameters {
        AudioDSPParameters(
            bandGainsDB: customBands,
            isCustomEQ: isCustomEQ,
            stereoBalance: stereoBalance,
            volumeBoostEnabled: volumeBoostEnabled,
            volumeBoostDB: volumeBoostDB,
            dynamicLevelingEnabled: dynamicLevelingEnabled,
            smartRepairEnabled: smartRepairEnabled,
            smartRepairIntensity: smartRepairIntensity,
            fadeGain: isUsingNativeVolumeFallback ? 1.0 : currentFadeGain
        )
    }

    /// 绑定 UserDefaults 持久化音效预设、AI 智能修音、响度增强与防爆音动态均衡
    public func bindPersistence(_ defaults: UserDefaults) {
        persistedDefaults = defaults
        isRestoringPreferences = true
        if let rawPreset = defaults.string(forKey: "dsnovel.v3.dsp.preset"),
           let restored = AudioEQPreset(rawValue: rawPreset) {
            preset = restored
        }
        if defaults.bool(forKey: "dsnovel.v3.dsp.isCustomEQ"),
           let savedBands = defaults.array(forKey: "dsnovel.v3.dsp.customBands") as? [Double],
           savedBands.count == 5 {
            isCustomEQ = true
            customBands = savedBands.map { Float($0) }
        }
        if defaults.object(forKey: "dsnovel.v3.dsp.volumeBoostDB") != nil {
            volumeBoostDB = defaults.float(forKey: "dsnovel.v3.dsp.volumeBoostDB")
        }
        dynamicLevelingEnabled = defaults.bool(forKey: "dsnovel.v3.dsp.dynamicLeveling")
        smartRepairEnabled = defaults.bool(forKey: "dsnovel.v3.dsp.smartRepairEnabled")
        if let rawIntensity = defaults.string(forKey: "dsnovel.v3.dsp.smartRepairIntensity"),
           let restoredIntensity = AudioSmartIntensity(rawValue: rawIntensity) {
            smartRepairIntensity = restoredIntensity
        }
        isRestoringPreferences = false
        pushParamsToProcessor()
    }

    private func persistPreferencesIfBound() {
        guard !isRestoringPreferences, let defaults = persistedDefaults else { return }
        defaults.set(preset.rawValue, forKey: "dsnovel.v3.dsp.preset")
        defaults.set(isCustomEQ, forKey: "dsnovel.v3.dsp.isCustomEQ")
        defaults.set(customBands.map { Double($0) }, forKey: "dsnovel.v3.dsp.customBands")
        defaults.set(volumeBoostDB, forKey: "dsnovel.v3.dsp.volumeBoostDB")
        defaults.set(dynamicLevelingEnabled, forKey: "dsnovel.v3.dsp.dynamicLeveling")
        defaults.set(smartRepairEnabled, forKey: "dsnovel.v3.dsp.smartRepairEnabled")
        defaults.set(smartRepairIntensity.rawValue, forKey: "dsnovel.v3.dsp.smartRepairIntensity")
    }

    public func prepareForStream(
        isHLS: Bool,
        mimeType: String?,
        assetURL: URL,
        deferWatchdogUntilPlaying: Bool = false,
        onSyncVolume: (@MainActor () -> Void)? = nil,
        onFallback: @escaping @MainActor () -> Void
    ) {
        watchdogTask?.cancel()
        watchdogTask = nil
        streamGeneration &+= 1
        tapReceiptReceived = false
        pendingFallbackHandler = nil
        volumeSyncHandler = onSyncVolume
        smartTelemetry = .idle

        let looksLikeHLS = isHLS
            || assetURL.pathExtension.lowercased() == "m3u8"
            || (mimeType?.lowercased().contains("mpegurl") == true)

        if looksLikeHLS {
            activateFallback(reason: "HLS 流媒体不支持音频 Tap，已自动切换为系统原生音量控制")
            onFallback()
            return
        }

        isUsingNativeVolumeFallback = false
        fallbackReason = nil
        pendingFallbackHandler = onFallback
        if let sync = volumeSyncHandler {
            sync()
        } else {
            pushParamsToProcessor()
        }

        if !deferWatchdogUntilPlaying {
            startWatchdogIfNeeded(for: streamGeneration)
        }
    }

    public func startWatchdogIfNeeded(for generation: UInt64? = nil) {
        let targetGen = generation ?? streamGeneration
        guard targetGen == streamGeneration,
              !isUsingNativeVolumeFallback,
              !tapReceiptReceived,
              watchdogTask == nil,
              let onFallback = pendingFallbackHandler else {
            return
        }

        let timeoutNs = watchdogTimeoutNanoseconds
        watchdogTask = Task { [weak self] in
            if timeoutNs > 0 {
                try? await Task.sleep(nanoseconds: timeoutNs)
            }
            guard !Task.isCancelled, let self,
                  self.streamGeneration == targetGen,
                  !self.tapReceiptReceived else {
                return
            }
            self.activateFallback(reason: "检测到无后缀流媒体或系统限制，已自动降级为原生音量控制")
            onFallback()
        }
    }

    public func buildAudioMix(for asset: AVAsset) async -> AVMutableAudioMix? {
        guard !isUsingNativeVolumeFallback else { return nil }
        let capturedGen = streamGeneration
        return await processor.buildAudioMix(
            for: asset,
            initialParams: currentParameters(),
            generation: capturedGen,
            onFirstReceipt: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.markTapReceiptReceived(for: capturedGen)
                }
            },
            onSmartTelemetry: { [weak self] telemetry in
                Task { @MainActor [weak self] in
                    self?.receiveSmartTelemetry(telemetry, for: capturedGen)
                }
            }
        )
    }

    public func markTapReceiptReceived(for generation: UInt64? = nil) {
        if let generation, generation != streamGeneration {
            return
        }
        tapReceiptReceived = true
        watchdogTask?.cancel()
        watchdogTask = nil
        pendingFallbackHandler = nil
        isUsingNativeVolumeFallback = false
        fallbackReason = nil
        if let sync = volumeSyncHandler {
            sync()
        } else {
            pushParamsToProcessor()
        }
    }

    public func activateFallback(reason: String) {
        watchdogTask?.cancel()
        watchdogTask = nil
        pendingFallbackHandler = nil
        isUsingNativeVolumeFallback = true
        fallbackReason = reason
        smartTelemetry = .idle
        processor.clearActiveContext()
    }

    public func applyFadeVolume(to player: AVPlayer, factor: Float) {
        let clamped = max(0, min(1, factor))
        currentFadeGain = clamped
        if isUsingNativeVolumeFallback {
            player.volume = clamped
            pushParamsToProcessor()
        } else {
            player.volume = 1.0
            pushParamsToProcessor()
        }
    }

    public func syncFadeVolume(to player: AVPlayer) {
        applyFadeVolume(to: player, factor: currentFadeGain)
    }

    public func resetWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
        pendingFallbackHandler = nil
        volumeSyncHandler = nil
        tapReceiptReceived = false
        smartTelemetry = .idle
        streamGeneration &+= 1
        processor.clearActiveContext()
    }

    private func receiveSmartTelemetry(_ telemetry: AudioSmartTelemetry, for generation: UInt64) {
        guard generation == streamGeneration, smartRepairEnabled, !isUsingNativeVolumeFallback else {
            return
        }
        if smartTelemetry != telemetry {
            smartTelemetry = telemetry
        }
    }

    private func scheduleDebouncedParamPush() {
        debouncePushTask?.cancel()
        debouncePushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(35))
            guard !Task.isCancelled, let self else { return }
            self.pushParamsToProcessor()
        }
    }

    private func pushParamsToProcessor() {
        debouncePushTask?.cancel()
        let params = currentParameters()
        processor.updateParameters(params)
        if params.needsProcessing && !isUsingNativeVolumeFallback {
            onParametersUpdated?()
        }
    }
}
