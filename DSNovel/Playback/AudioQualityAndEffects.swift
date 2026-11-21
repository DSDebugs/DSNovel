import Foundation
import AVFoundation
import AudioToolbox
import MediaToolbox
import Accelerate
import Observation
import os

/// 倍速格式化工具：解决 `%.2gx` 将 `1.25x` 四舍五入截断为 `1.2x` 的缺陷（ISS-04）
enum PlayerSpeedFormatter {
    nonisolated static func format(_ speed: Double) -> String {
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

/// 当前章节音质可调能力分级（音源/章节级能力感知）
enum AudioQualitySupportMode: Equatable, Sendable {
    /// 原生多码率书源/通道（当前仅喜马拉雅：走官方 playUrlList 多档）
    case multiBitrate
    /// 服务端固定单码率书源/通道（听友、云图、博看、听书网）
    case fixedSingleBitrate
    /// 本地已下载离线音频
    case localOffline
}

/// 音质档位（纯 4 档：智能自适应 / 标准 / 高清 / 超清）
///
/// 档位 → 各链码的映射集中在 `QualityPolicy`，本类型只负责展示、独立码率核算与本地缓冲策略。
enum AudioQualityTier: String, CaseIterable, Identifiable, Codable, Sendable {
    case auto = "auto"   // 智能自适应（Wi-Fi → 超清；移动网络 → 标准）
    case std  = "std"    // 标准（书源链 M4A_24 / 解析器链 std）
    case hd   = "hd"     // 高清（书源链 M4A_64 / 解析器链 hd）
    case uhd  = "uhd"    // 超清（书源链 M4A_128 / 解析器链 uhd）

    /// 面板与设置页展示的 4 个可见档位
    static let visibleTiers: [AudioQualityTier] = [.auto, .std, .hd, .uhd]

    /// 全局默认音质档位
    static let defaultTier: AudioQualityTier = .hd

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "智能自适应"
        case .std: return "标准"
        case .hd: return "高清"
        case .uhd: return "超清"
        }
    }

    var badgeText: String {
        switch self {
        case .auto: return "自适应"
        case .std: return "标准·24k"
        case .hd: return "高清·48k"
        case .uhd: return "超清·96k"
        }
    }

    nonisolated func effectiveBadgeText(isOnWiFi: Bool) -> String {
        switch self {
        case .auto: return isOnWiFi ? "自适应·96k" : "自适应·24k"
        case .std: return "标准·24k"
        case .hd: return "高清·48k"
        case .uhd: return "超清·96k"
        }
    }

    /// 独立码率核算分桶：`< 36` → 标准，`36...71` → 高清，`>= 72` → 超清
    nonisolated static func tierLabel(forBitrateKbps kbps: Int) -> String {
        if kbps < 36 {
            return "标准"
        } else if kbps <= 71 {
            return "高清"
        } else {
            return "超清"
        }
    }

    /// 将实测或核算得到的码率（kbps）格式化为徽标文案（如「标准·24k」「高清·48k」「超清·96k」）
    nonisolated static func badgeText(forDetectedBitrateKbps rawKbps: Int) -> String {
        guard rawKbps > 0 else { return "" }
        return "\(tierLabel(forBitrateKbps: rawKbps))·\(rawKbps)k"
    }

    /// 根据音频字节数与时长（秒）独立核算平均码率（kbps）
    nonisolated static func computedBitrateKbps(bytes: Int64, durationSec: Double) -> Int? {
        guard bytes > 0, durationSec > 1 else { return nil }
        let kbps = Int((Double(bytes) * 8.0 / durationSec / 1000.0).rounded())
        return kbps > 0 ? kbps : nil
    }

    /// 时长未知时的文件体积兜底展示
    nonisolated static func formattedSizeFallback(bytes: Int64) -> String {
        guard bytes > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var subtitle: String {
        switch self {
        case .auto: return "Wi-Fi 下优选超清，移动网络下自动切换至标准音质"
        case .std: return "约 24k，流量占用极低，适合弱网与移动网络收听"
        case .hd: return "约 48k，默认推荐，清晰人声与体积占用平衡"
        case .uhd: return "约 96k，保留饱满演播细节与配乐，需会员账号权限"
        }
    }

    nonisolated var preferredForwardBufferDuration: TimeInterval {
        switch self {
        case .std: return 10.0
        case .auto: return 15.0
        case .hd: return 18.0
        case .uhd: return 24.0
        }
    }
}

/// 六种听书专属音效预设（§3.2.2）
enum AudioEffectPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case original = "original"
    case clearVoice = "clearVoice"
    case warmTheater = "warmTheater"
    case nightSoft = "nightSoft"
    case noiseReduction = "noiseReduction"
    case custom = "custom"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "原声直通"
        case .clearVoice: return "人声清澈"
        case .warmTheater: return "剧场沉浸"
        case .nightSoft: return "深夜助眠"
        case .noiseReduction: return "降噪增强"
        case .custom: return "自定义 EQ"
        }
    }

    var shortBadge: String {
        switch self {
        case .original: return "音效"
        case .clearVoice: return "人声清澈"
        case .warmTheater: return "剧场沉浸"
        case .nightSoft: return "深夜助眠"
        case .noiseReduction: return "降噪增强"
        case .custom: return "自定义EQ"
        }
    }

    var subtitle: String {
        switch self {
        case .original: return "保持书源原始录音质感，不做额外频响染色"
        case .clearVoice: return "提升 1kHz–3.3kHz 演播人声频段，抑制低频混浊，咬字更清晰"
        case .warmTheater: return "增强中低频胸腔共鸣与空间混响感，适合多人精品有声剧"
        case .nightSoft: return "柔化高频齿音与突发响度，睡前低音量收听更柔和护耳"
        case .noiseReduction: return "衰减 100Hz 以下底噪与高频嘶声，适合老旧评书或低码率音源"
        case .custom: return "手动调节五段均衡器频响增益（-12dB 至 +12dB）"
        }
    }

    var iconName: String {
        switch self {
        case .original: return "waveform"
        case .clearVoice: return "person.wave.2.fill"
        case .warmTheater: return "theatermasks.fill"
        case .nightSoft: return "moon.stars.fill"
        case .noiseReduction: return "ear.badge.checkmark"
        case .custom: return "slider.vertical.3"
        }
    }

    nonisolated var defaultBandsDb: [Double] {
        switch self {
        case .original: return [0.0, 0.0, 0.0, 0.0, 0.0]
        case .clearVoice: return [-3.5, -1.0, 3.5, 4.5, 1.5]
        case .warmTheater: return [3.5, 2.5, 0.5, 1.5, 2.0]
        case .nightSoft: return [1.0, 2.0, 1.0, -2.5, -4.5]
        case .noiseReduction: return [-6.0, -1.5, 4.0, 3.0, -4.0]
        case .custom: return [0.0, 0.0, 0.0, 0.0, 0.0]
        }
    }

    nonisolated var timePitchAlgorithm: AVAudioTimePitchAlgorithm {
        switch self {
        case .warmTheater: return .spectral
        default: return .timeDomain
        }
    }
}

/// 五段人声均衡器频点定义（100Hz / 330Hz / 1kHz / 3.3kHz / 10kHz）
struct EqualizerBandSpec: Identifiable, Equatable, Sendable {
    let index: Int
    let frequencyHz: Float
    let label: String
    let role: String
    var id: Int { index }

    static let standardFiveBands: [EqualizerBandSpec] = [
        EqualizerBandSpec(index: 0, frequencyHz: 100, label: "100Hz", role: "低频底噪/氛围"),
        EqualizerBandSpec(index: 1, frequencyHz: 330, label: "330Hz", role: "胸腔温暖感"),
        EqualizerBandSpec(index: 2, frequencyHz: 1000, label: "1kHz", role: "人声主体"),
        EqualizerBandSpec(index: 3, frequencyHz: 3300, label: "3.3kHz", role: "咬字清晰度"),
        EqualizerBandSpec(index: 4, frequencyHz: 10000, label: "10kHz", role: "空气感/齿音")
    ]
}

/// 当前音频输出外设快照（供音效面板与路由状态展示）
struct AudioRouteSnapshot: Equatable, Sendable {
    let portName: String
    let portTypeRaw: String
    let iconName: String
    let isExternalHeadphones: Bool

    static func current() -> AudioRouteSnapshot {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard let first = outputs.first else {
            return AudioRouteSnapshot(
                portName: "iPhone 扬声器",
                portTypeRaw: AVAudioSession.Port.builtInSpeaker.rawValue,
                iconName: "speaker.wave.2.fill",
                isExternalHeadphones: false
            )
        }
        let portType = first.portType
        let icon: String
        let isHeadphones: Bool
        switch portType {
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP:
            icon = "airpodspro"
            isHeadphones = true
        case .headphones, .headsetMic, .usbAudio:
            icon = "headphones"
            isHeadphones = true
        case .airPlay:
            icon = "airplayaudio"
            isHeadphones = false
        case .carAudio:
            icon = "car.fill"
            isHeadphones = false
        default:
            icon = "speaker.wave.2.fill"
            isHeadphones = false
        }
        return AudioRouteSnapshot(
            portName: first.portName.isEmpty ? "iPhone 扬声器" : first.portName,
            portTypeRaw: portType.rawValue,
            iconName: icon,
            isExternalHeadphones: isHeadphones
        )
    }
}

// MARK: - MTAudioProcessingTap 实时 5 段 Direct Form II Transposed 双二阶 EQ + 声道平衡 + 软限幅器

final class AudioTapDSPContext: @unchecked Sendable {
    struct BiquadSectionCoeffs: Equatable, Sendable {
        var b0: Float
        var b1: Float
        var b2: Float
        var a1: Float
        var a2: Float

        static let identity = BiquadSectionCoeffs(b0: 1.0, b1: 0.0, b2: 0.0, a1: 0.0, a2: 0.0)
    }

    struct FiveBandBiquadCoeffs: Equatable, Sendable {
        var s0: BiquadSectionCoeffs
        var s1: BiquadSectionCoeffs
        var s2: BiquadSectionCoeffs
        var s3: BiquadSectionCoeffs
        var s4: BiquadSectionCoeffs
        var eqActive: Bool

        static let bypass = FiveBandBiquadCoeffs(
            s0: .identity,
            s1: .identity,
            s2: .identity,
            s3: .identity,
            s4: .identity,
            eqActive: false
        )
    }

    private struct BiquadSectionState {
        var z1: Float = 0.0
        var z2: Float = 0.0
    }

    private struct ChannelBiquadStates {
        var s0 = BiquadSectionState()
        var s1 = BiquadSectionState()
        var s2 = BiquadSectionState()
        var s3 = BiquadSectionState()
        var s4 = BiquadSectionState()
    }

    private struct Params: Equatable {
        var b0: Double = 0.0
        var b1: Double = 0.0
        var b2: Double = 0.0
        var b3: Double = 0.0
        var b4: Double = 0.0
        var sampleRate: Double = 44100.0
        var coeffs: FiveBandBiquadCoeffs = .bypass
        var balance: Double = 0.0
        var mixGain: Float = 1.0
        var generation: UInt64 = 1
        var hasPrepared: Bool = false
    }

    private let lock = OSAllocatedUnfairLock(initialState: Params())
    private let onPreparedLock = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

    // 音频渲染线程私有状态（仅在 prepare / process / unprepare 回调访问，无锁、无堆分配）
    private var sampleRate: Double = 44100.0
    private var isFloatFormat: Bool = true
    private var isNonInterleaved: Bool = true
    private var channelsPerFrame: UInt32 = 2
    private var maxBlockFrames: Int = 4096
    private var lastParams: Params = Params()
    private var channelStates: [ChannelBiquadStates] = []

    nonisolated init(
        bandsDb: [Double],
        balance: Double,
        mixGain: Float,
        onPrepared: (@Sendable () -> Void)? = nil
    ) {
        onPreparedLock.withLock { $0 = onPrepared }
        update(bandsDb: bandsDb, balance: balance, mixGain: mixGain)
    }

    /// AVFoundation 是否已实际回调 MTAudioProcessingTap prepare（用于识别无后缀 HLS 静默忽略 Tap 的情形）
    nonisolated var hasPreparedReceipt: Bool {
        lock.withLock { $0.hasPrepared }
    }

    /// 控制线程更新参数：在此完成 5 段双二阶系数计算，实时音频线程不再做三角函数或堆分配
    nonisolated func update(bandsDb: [Double], balance: Double, mixGain: Float) {
        let n0 = min(max(0 < bandsDb.count ? bandsDb[0] : 0.0, -12.0), 12.0)
        let n1 = min(max(1 < bandsDb.count ? bandsDb[1] : 0.0, -12.0), 12.0)
        let n2 = min(max(2 < bandsDb.count ? bandsDb[2] : 0.0, -12.0), 12.0)
        let n3 = min(max(3 < bandsDb.count ? bandsDb[3] : 0.0, -12.0), 12.0)
        let n4 = min(max(4 < bandsDb.count ? bandsDb[4] : 0.0, -12.0), 12.0)
        let clampedBalance = min(max(balance, -1.0), 1.0)
        let clampedGain = min(max(mixGain, 0.0), 4.0)

        let currentSampleRate = lock.withLock { $0.sampleRate }
        let computedCoeffs = Self.computeFiveBandCoeffs(
            b0: n0, b1: n1, b2: n2, b3: n3, b4: n4,
            sampleRate: currentSampleRate
        )

        lock.withLock { state in
            let finalCoeffs: FiveBandBiquadCoeffs
            if state.sampleRate == currentSampleRate {
                finalCoeffs = computedCoeffs
            } else {
                finalCoeffs = Self.computeFiveBandCoeffs(
                    b0: n0, b1: n1, b2: n2, b3: n3, b4: n4,
                    sampleRate: state.sampleRate
                )
            }
            if state.b0 != n0 || state.b1 != n1 || state.b2 != n2 || state.b3 != n3 || state.b4 != n4 {
                state.b0 = n0
                state.b1 = n1
                state.b2 = n2
                state.b3 = n3
                state.b4 = n4
                state.coeffs = finalCoeffs
                state.generation &+= 1
            } else if state.coeffs != finalCoeffs {
                state.coeffs = finalCoeffs
                state.generation &+= 1
            }
            state.balance = clampedBalance
            state.mixGain = clampedGain
        }
    }

    fileprivate nonisolated func prepare(format: AudioStreamBasicDescription, maxFrames: CMItemCount) {
        let resolvedRate = format.mSampleRate > 0 ? format.mSampleRate : 44100.0
        sampleRate = resolvedRate
        isFloatFormat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        isNonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        channelsPerFrame = max(1, format.mChannelsPerFrame)

        let chCount = Int(max(2, channelsPerFrame))
        channelStates = Array(repeating: ChannelBiquadStates(), count: chCount)

        let resolvedMaxFrames = max(Int(maxFrames), 1024)
        maxBlockFrames = resolvedMaxFrames

        var shouldNotifyPrepared = false
        let snapshot: Params = lock.withLock { state in
            if !state.hasPrepared {
                state.hasPrepared = true
                shouldNotifyPrepared = true
            }
            if state.sampleRate != resolvedRate {
                state.sampleRate = resolvedRate
                state.coeffs = Self.computeFiveBandCoeffs(
                    b0: state.b0, b1: state.b1, b2: state.b2, b3: state.b3, b4: state.b4,
                    sampleRate: resolvedRate
                )
                state.generation &+= 1
            }
            return state
        }
        lastParams = snapshot
        if shouldNotifyPrepared, let callback = onPreparedLock.withLock({ $0 }) {
            callback()
        }
    }

    fileprivate nonisolated func unprepare() {
        channelStates.removeAll(keepingCapacity: false)
        maxBlockFrames = 0
    }

    /// 仅供单元测试调用的准备入口
    nonisolated func prepareForTesting(
        sampleRate: Double = 44100.0,
        channels: UInt32 = 2,
        maxFrames: Int = 1024,
        isNonInterleaved: Bool = true
    ) {
        var flags: AudioFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        if isNonInterleaved {
            flags |= kAudioFormatFlagIsNonInterleaved
        }
        let asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: flags,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        prepare(format: asbd, maxFrames: CMItemCount(maxFrames))
    }

    /// 仅供单元测试调用的实时处理入口（无堆分配）
    nonisolated func processBufferListForTesting(
        frameCount: Int,
        bufferList: UnsafeMutablePointer<AudioBufferList>
    ) {
        process(frameCount: frameCount, bufferListInOut: bufferList)
    }

    /// 计算单段双二阶系数（100Hz Low-Shelf / 330Hz, 1kHz, 3.3kHz Peaking / 10kHz High-Shelf）
    private nonisolated static func computeSingleSectionCoeffs(
        bandIndex idx: Int,
        rawDb: Double,
        sampleRate: Double
    ) -> (b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        let db = min(max(rawDb, -12.0), 12.0)
        if abs(db) < 0.05 {
            return (1.0, 0.0, 0.0, 0.0, 0.0)
        }
        let fs = max(8000.0, sampleRate)
        let rawFreq: Double
        switch idx {
        case 0: rawFreq = 100.0
        case 1: rawFreq = 330.0
        case 2: rawFreq = 1000.0
        case 3: rawFreq = 3300.0
        default: rawFreq = 10000.0
        }
        let freq = min(rawFreq, fs * 0.45)
        let w0 = 2.0 * Double.pi * freq / fs
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let aAmp = pow(10.0, db / 40.0)

        let cb0, cb1, cb2, ca0, ca1, ca2: Double
        if idx == 0 {
            // Low-Shelf (S = 1.0)
            let alpha = sinW0 / 2.0 * sqrt(2.0)
            let twoSqrtAAlpha = 2.0 * sqrt(aAmp) * alpha
            cb0 = aAmp * ((aAmp + 1.0) - (aAmp - 1.0) * cosW0 + twoSqrtAAlpha)
            cb1 = 2.0 * aAmp * ((aAmp - 1.0) - (aAmp + 1.0) * cosW0)
            cb2 = aAmp * ((aAmp + 1.0) - (aAmp - 1.0) * cosW0 - twoSqrtAAlpha)
            ca0 = (aAmp + 1.0) + (aAmp - 1.0) * cosW0 + twoSqrtAAlpha
            ca1 = -2.0 * ((aAmp - 1.0) + (aAmp + 1.0) * cosW0)
            ca2 = (aAmp + 1.0) + (aAmp - 1.0) * cosW0 - twoSqrtAAlpha
        } else if idx == 4 {
            // High-Shelf (S = 1.0)
            let alpha = sinW0 / 2.0 * sqrt(2.0)
            let twoSqrtAAlpha = 2.0 * sqrt(aAmp) * alpha
            cb0 = aAmp * ((aAmp + 1.0) + (aAmp - 1.0) * cosW0 + twoSqrtAAlpha)
            cb1 = -2.0 * aAmp * ((aAmp - 1.0) + (aAmp + 1.0) * cosW0)
            cb2 = aAmp * ((aAmp + 1.0) + (aAmp - 1.0) * cosW0 - twoSqrtAAlpha)
            ca0 = (aAmp + 1.0) - (aAmp - 1.0) * cosW0 + twoSqrtAAlpha
            ca1 = 2.0 * ((aAmp - 1.0) - (aAmp + 1.0) * cosW0)
            ca2 = (aAmp + 1.0) - (aAmp - 1.0) * cosW0 - twoSqrtAAlpha
        } else {
            // Peaking EQ (Q = 1.414, ~1 octave bandwidth)
            let q = 1.41421356
            let alpha = sinW0 / (2.0 * q)
            cb0 = 1.0 + alpha * aAmp
            cb1 = -2.0 * cosW0
            cb2 = 1.0 - alpha * aAmp
            ca0 = 1.0 + alpha / aAmp
            ca1 = -2.0 * cosW0
            ca2 = 1.0 - alpha / aAmp
        }
        let invA0 = abs(ca0) > 1e-12 ? (1.0 / ca0) : 1.0
        return (cb0 * invA0, cb1 * invA0, cb2 * invA0, ca1 * invA0, ca2 * invA0)
    }

    nonisolated static func computeFiveBandCoeffs(
        b0: Double, b1: Double, b2: Double, b3: Double, b4: Double,
        sampleRate: Double
    ) -> FiveBandBiquadCoeffs {
        let hasActiveBand = abs(b0) >= 0.05
            || abs(b1) >= 0.05
            || abs(b2) >= 0.05
            || abs(b3) >= 0.05
            || abs(b4) >= 0.05
        guard hasActiveBand else { return .bypass }

        let c0 = computeSingleSectionCoeffs(bandIndex: 0, rawDb: b0, sampleRate: sampleRate)
        let c1 = computeSingleSectionCoeffs(bandIndex: 1, rawDb: b1, sampleRate: sampleRate)
        let c2 = computeSingleSectionCoeffs(bandIndex: 2, rawDb: b2, sampleRate: sampleRate)
        let c3 = computeSingleSectionCoeffs(bandIndex: 3, rawDb: b3, sampleRate: sampleRate)
        let c4 = computeSingleSectionCoeffs(bandIndex: 4, rawDb: b4, sampleRate: sampleRate)

        return FiveBandBiquadCoeffs(
            s0: BiquadSectionCoeffs(b0: Float(c0.b0), b1: Float(c0.b1), b2: Float(c0.b2), a1: Float(c0.a1), a2: Float(c0.a2)),
            s1: BiquadSectionCoeffs(b0: Float(c1.b0), b1: Float(c1.b1), b2: Float(c1.b2), a1: Float(c1.a1), a2: Float(c1.a2)),
            s2: BiquadSectionCoeffs(b0: Float(c2.b0), b1: Float(c2.b1), b2: Float(c2.b2), a1: Float(c2.a1), a2: Float(c2.a2)),
            s3: BiquadSectionCoeffs(b0: Float(c3.b0), b1: Float(c3.b1), b2: Float(c3.b2), a1: Float(c3.a1), a2: Float(c3.a2)),
            s4: BiquadSectionCoeffs(b0: Float(c4.b0), b1: Float(c4.b1), b2: Float(c4.b2), a1: Float(c4.a1), a2: Float(c4.a2)),
            eqActive: true
        )
    }

    /// 计算 5 段双二阶滤波器系数（兼容既有外部调用）
    nonisolated static func writeFiveBandBiquadCoefficients(
        b0: Double, b1: Double, b2: Double, b3: Double, b4: Double,
        sampleRate: Double,
        into out: UnsafeMutablePointer<Double>
    ) {
        let dbs = (b0, b1, b2, b3, b4)
        for idx in 0..<5 {
            let rawDb: Double = idx == 0 ? dbs.0 : (idx == 1 ? dbs.1 : (idx == 2 ? dbs.2 : (idx == 3 ? dbs.3 : dbs.4)))
            let c = computeSingleSectionCoeffs(bandIndex: idx, rawDb: rawDb, sampleRate: sampleRate)
            let base = idx * 5
            out[base + 0] = c.b0
            out[base + 1] = c.b1
            out[base + 2] = c.b2
            out[base + 3] = c.a1
            out[base + 4] = c.a2
        }
    }

    nonisolated static func computeFiveBandBiquadCoefficients(
        bandsDb: [Double],
        sampleRate: Double
    ) -> [Double] {
        var coeffs: [Double] = []
        coeffs.reserveCapacity(25)
        for idx in 0..<5 {
            let rawDb = idx < bandsDb.count ? bandsDb[idx] : 0.0
            let c = computeSingleSectionCoeffs(bandIndex: idx, rawDb: rawDb, sampleRate: sampleRate)
            coeffs.append(c.b0)
            coeffs.append(c.b1)
            coeffs.append(c.b2)
            coeffs.append(c.a1)
            coeffs.append(c.a2)
        }
        return coeffs
    }

    fileprivate nonisolated func process(
        frameCount: Int,
        bufferListInOut: UnsafeMutablePointer<AudioBufferList>
    ) {
        guard isFloatFormat, frameCount > 0 else { return }
        if let fresh = lock.withLockIfAvailable({ $0 }) {
            lastParams = fresh
        }
        let params = lastParams
        let coeffs = params.coeffs
        let eqActive = coeffs.eqActive

        let balance = params.balance
        let leftPan: Float = balance <= 0 ? 1.0 : Float(max(0.0, 1.0 - balance))
        let rightPan: Float = balance >= 0 ? 1.0 : Float(max(0.0, 1.0 + balance))
        let baseGain = params.mixGain
        let needsGainOrLimit = eqActive || abs(baseGain - 1.0) > 0.001 || abs(balance) > 0.001

        guard needsGainOrLimit else { return }

        let chunkCap = max(maxBlockFrames, 1)
        let abl = UnsafeMutableAudioBufferListPointer(bufferListInOut)

        if isNonInterleaved {
            for bufIdx in 0..<abl.count {
                guard let rawData = abl[bufIdx].mData else { continue }
                let samples = rawData.assumingMemoryBound(to: Float.self)
                let count = min(frameCount, Int(abl[bufIdx].mDataByteSize) / MemoryLayout<Float>.size)
                guard count > 0 else { continue }

                let panGain: Float = {
                    if abl.count >= 2 {
                        return bufIdx == 0 ? leftPan : (bufIdx == 1 ? rightPan : 1.0)
                    }
                    return 1.0
                }()
                let totalGain = baseGain * panGain
                let enableLimiter = totalGain > 1.01 || eqActive

                var offset = 0
                while offset < count {
                    let chunk = min(count - offset, chunkCap)
                    let chunkPtr = samples.advanced(by: offset)
                    if eqActive && bufIdx < channelStates.count {
                        Self.applyFiveBandDF2T(
                            samples: chunkPtr,
                            frameCount: chunk,
                            stride: 1,
                            coeffs: coeffs,
                            state: &channelStates[bufIdx]
                        )
                    }
                    Self.applyGainAndSoftLimiter(
                        samples: chunkPtr,
                        count: chunk,
                        gain: totalGain,
                        enableLimiter: enableLimiter
                    )
                    offset += chunk
                }
            }
        } else if abl.count == 1, let rawData = abl[0].mData {
            // Interleaved PCM (e.g., stereo L,R,L,R)
            let chCount = Int(max(1, abl[0].mNumberChannels))
            let totalSamples = min(frameCount * chCount, Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size)
            let actualFrames = totalSamples / chCount
            guard actualFrames > 0 else { return }
            let samples = rawData.assumingMemoryBound(to: Float.self)

            for ch in 0..<chCount {
                let panGain: Float = {
                    if chCount >= 2 {
                        return ch == 0 ? leftPan : (ch == 1 ? rightPan : 1.0)
                    }
                    return 1.0
                }()
                let totalGain = baseGain * panGain
                let enableLimiter = totalGain > 1.01 || eqActive

                var frameOffset = 0
                while frameOffset < actualFrames {
                    let chunk = min(actualFrames - frameOffset, chunkCap)
                    let chPtr = samples.advanced(by: frameOffset * chCount + ch)
                    if eqActive && ch < channelStates.count {
                        Self.applyFiveBandDF2T(
                            samples: chPtr,
                            frameCount: chunk,
                            stride: chCount,
                            coeffs: coeffs,
                            state: &channelStates[ch]
                        )
                    }
                    for i in 0..<chunk {
                        let idx = i * chCount
                        let scaled = chPtr[idx] * totalGain
                        chPtr[idx] = enableLimiter ? Self.softLimitSample(scaled) : scaled
                    }
                    frameOffset += chunk
                }
            }
        }
    }

    @inline(__always)
    private nonisolated static func stepBiquadDF2T(
        _ x: Float,
        coeffs c: BiquadSectionCoeffs,
        state s: inout BiquadSectionState
    ) -> Float {
        let y = c.b0 * x + s.z1
        s.z1 = c.b1 * x - c.a1 * y + s.z2
        s.z2 = c.b2 * x - c.a2 * y
        return y
    }

    /// 无堆分配 5 段级联 Direct Form II Transposed 双二阶滤波（不重置延迟状态以保证系数切换连续无爆音）
    private nonisolated static func applyFiveBandDF2T(
        samples: UnsafeMutablePointer<Float>,
        frameCount: Int,
        stride: Int,
        coeffs: FiveBandBiquadCoeffs,
        state: inout ChannelBiquadStates
    ) {
        var s0 = state.s0
        var s1 = state.s1
        var s2 = state.s2
        var s3 = state.s3
        var s4 = state.s4
        let c0 = coeffs.s0
        let c1 = coeffs.s1
        let c2 = coeffs.s2
        let c3 = coeffs.s3
        let c4 = coeffs.s4

        var idx = 0
        for _ in 0..<frameCount {
            var y = samples[idx]
            y = stepBiquadDF2T(y, coeffs: c0, state: &s0)
            y = stepBiquadDF2T(y, coeffs: c1, state: &s1)
            y = stepBiquadDF2T(y, coeffs: c2, state: &s2)
            y = stepBiquadDF2T(y, coeffs: c3, state: &s3)
            y = stepBiquadDF2T(y, coeffs: c4, state: &s4)
            samples[idx] = y
            idx += stride
        }

        state.s0 = s0
        state.s1 = s1
        state.s2 = s2
        state.s3 = s3
        state.s4 = s4
    }

    @inline(__always)
    private nonisolated static func softLimitSample(_ x: Float) -> Float {
        let threshold: Float = 0.85
        let headroom: Float = 0.14
        let ax = abs(x)
        if ax <= threshold {
            return x
        }
        let excess = (ax - threshold) / headroom
        let compressed = threshold + headroom * tanhf(excess)
        return x >= 0 ? compressed : -compressed
    }

    private nonisolated static func applyGainAndSoftLimiter(
        samples: UnsafeMutablePointer<Float>,
        count: Int,
        gain: Float,
        enableLimiter: Bool
    ) {
        if !enableLimiter {
            var g = gain
            vDSP_vsmul(samples, 1, &g, samples, 1, vDSP_Length(count))
            return
        }
        for i in 0..<count {
            samples[i] = softLimitSample(samples[i] * gain)
        }
    }
}

private let dsAudioTapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, tapStorageOut in
    tapStorageOut.pointee = clientInfo
}

private let dsAudioTapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    let storage = MTAudioProcessingTapGetStorage(tap)
    Unmanaged<AudioTapDSPContext>.fromOpaque(storage).release()
}

private let dsAudioTapPrepare: MTAudioProcessingTapPrepareCallback = { tap, maxFrames, processingFormat in
    let storage = MTAudioProcessingTapGetStorage(tap)
    let ctx = Unmanaged<AudioTapDSPContext>.fromOpaque(storage).takeUnretainedValue()
    ctx.prepare(format: processingFormat.pointee, maxFrames: maxFrames)
}

private let dsAudioTapUnprepare: MTAudioProcessingTapUnprepareCallback = { tap in
    let storage = MTAudioProcessingTapGetStorage(tap)
    let ctx = Unmanaged<AudioTapDSPContext>.fromOpaque(storage).takeUnretainedValue()
    ctx.unprepare()
}

private let dsAudioTapProcess: MTAudioProcessingTapProcessCallback = { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
    let status = MTAudioProcessingTapGetSourceAudio(
        tap,
        numberFrames,
        bufferListInOut,
        flagsOut,
        nil,
        numberFramesOut
    )
    guard status == noErr, numberFramesOut.pointee > 0 else { return }
    let storage = MTAudioProcessingTapGetStorage(tap)
    let ctx = Unmanaged<AudioTapDSPContext>.fromOpaque(storage).takeUnretainedValue()
    ctx.process(frameCount: Int(numberFramesOut.pointee), bufferListInOut: bufferListInOut)
}

/// 播放器音频处理管线：流媒体变调/响度补偿 + MTAudioProcessingTap 5 段 DF2T 双二阶 EQ / 声道平衡 / 软限幅器
enum PlayerAudioPipeline {
    nonisolated static func linearGainFromDecibels(_ db: Float) -> Float {
        let clampedDb = min(max(db, -12.0), 12.0)
        return pow(10.0, clampedDb / 20.0)
    }

    nonisolated static func computeEffectiveVolume(
        bookVolume: Double,
        preset: AudioEffectPreset,
        eqBandsDb: [Double],
        boostDB: Double = 0.0
    ) -> (playerVolume: Float, mixGain: Float, isBoosted: Bool) {
        let clampedBook = min(max(bookVolume, 0.0), 2.0)
        if clampedBook <= 0.001 {
            return (0.0, 0.0, false)
        }
        let voiceBandAvgDb = eqBandsDb.count >= 4 ? (eqBandsDb[2] + eqBandsDb[3]) / 2.0 : 0.0
        let presetBoostFactor: Double = {
            switch preset {
            case .clearVoice: return 1.08
            case .noiseReduction: return 1.10
            case .nightSoft: return 0.90
            default: return 1.0
            }
        }()
        let eqLinearFactor = pow(10.0, min(max(voiceBandAvgDb, -6.0), 6.0) / 40.0)
        let extraBoostLinear = Double(linearGainFromDecibels(Float(min(max(boostDB, 0.0), 12.0))))
        let combined = clampedBook * presetBoostFactor * eqLinearFactor * extraBoostLinear
        let playerVol = Float(min(max(combined, 0.0), 1.0))
        let mixGain = Float(min(max(combined, 0.0), 3.99))
        let boosted = clampedBook > 1.01 || boostDB > 0.05
        return (playerVol, mixGain, boosted)
    }

    nonisolated static func isHLSAsset(
        _ asset: AVAsset,
        streamKind: StreamKind = .onDemand,
        contentTypeHint: String? = nil
    ) -> Bool {
        if streamKind == .hls { return true }
        if let hint = contentTypeHint?.lowercased(),
           hint.contains("mpegurl") || hint.contains("hls") {
            return true
        }
        guard let urlAsset = asset as? AVURLAsset else { return false }
        let url = urlAsset.url
        if url.isFileURL { return false }
        let ext = url.pathExtension.lowercased()
        let absLower = url.absoluteString.lowercased()
        if ext == "m3u8" || absLower.contains(".m3u8") || absLower.contains("format=hls") || absLower.contains("type=hls") {
            return true
        }
        return false
    }

    /// 异步结合 AVURLAsset.variants 识别无 .m3u8 后缀的 HLS 自适应流
    nonisolated static func isHLSAssetAsync(
        _ asset: AVAsset,
        streamKind: StreamKind = .onDemand,
        contentTypeHint: String? = nil
    ) async -> Bool {
        if isHLSAsset(asset, streamKind: streamKind, contentTypeHint: contentTypeHint) {
            return true
        }
        guard let urlAsset = asset as? AVURLAsset, !urlAsset.url.isFileURL else {
            return false
        }
        if let variants = try? await urlAsset.load(.variants), !variants.isEmpty {
            return true
        }
        return false
    }

    nonisolated static func applyToPlayerItem(
        _ item: AVPlayerItem,
        preset: AudioEffectPreset,
        audioChannel: AudioChannelMode,
        bookVolume: Double,
        eqBandsDb: [Double],
        boostDB: Double = 0.0,
        balance: Double = 0.0,
        qualityTier: AudioQualityTier = .hd
    ) {
        item.audioTimePitchAlgorithm = (audioChannel == .spokenAudio && preset != .warmTheater)
            ? .timeDomain
            : preset.timePitchAlgorithm
        item.preferredForwardBufferDuration = qualityTier.preferredForwardBufferDuration
    }

    nonisolated static func makeAudioMixIfNeeded(
        for asset: AVAsset,
        mixGain: Float
    ) async -> AVAudioMix? {
        guard mixGain > 1.01 else { return nil }
        guard !isHLSAsset(asset) else { return nil }
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio),
              let firstTrack = tracks.first else {
            return nil
        }
        let mix = AVMutableAudioMix()
        let params = AVMutableAudioMixInputParameters(track: firstTrack)
        params.setVolume(min(mixGain, 3.99), at: .zero)
        mix.inputParameters = [params]
        return mix
    }

    /// 构建接入 `MTAudioProcessingTap` 的 `AVAudioMix`（5 段 DF2T 双二阶 EQ + 声道平衡 + 软限幅器）
    /// 对 HLS `.m3u8` 或无音轨资源返回 `nil`。
    nonisolated static func makeAudioTapMix(
        for asset: AVAsset,
        context: AudioTapDSPContext,
        streamKind: StreamKind = .onDemand,
        contentTypeHint: String? = nil
    ) async -> AVAudioMix? {
        guard !(await isHLSAssetAsync(asset, streamKind: streamKind, contentTypeHint: contentTypeHint)) else { return nil }
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio),
              let firstTrack = tracks.first else {
            return nil
        }

        let retainedClientInfo = Unmanaged.passRetained(context).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: retainedClientInfo,
            init: dsAudioTapInit,
            finalize: dsAudioTapFinalize,
            prepare: dsAudioTapPrepare,
            unprepare: dsAudioTapUnprepare,
            process: dsAudioTapProcess
        )

        var tapOut: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PreEffects,
            &tapOut
        )
        guard status == noErr, let tap = tapOut else {
            Unmanaged<AudioTapDSPContext>.fromOpaque(retainedClientInfo).release()
            return nil
        }

        let mix = AVMutableAudioMix()
        let params = AVMutableAudioMixInputParameters(track: firstTrack)
        params.audioTapProcessor = tap
        mix.inputParameters = [params]
        return mix
    }

    nonisolated static func makeConfiguredEQNode(bandsDb: [Double]) -> AVAudioUnitEQ {
        let specs = EqualizerBandSpec.standardFiveBands
        let eq = AVAudioUnitEQ(numberOfBands: specs.count)
        for spec in specs where spec.index < eq.bands.count {
            let band = eq.bands[spec.index]
            band.frequency = spec.frequencyHz
            band.bandwidth = 1.0
            band.filterType = spec.index == 0
                ? .lowShelf
                : (spec.index == specs.count - 1 ? .highShelf : .parametric)
            let rawDb = spec.index < bandsDb.count ? bandsDb[spec.index] : 0.0
            band.gain = Float(min(max(rawDb, -12.0), 12.0))
            band.bypass = abs(band.gain) < 0.05
        }
        return eq
    }
}
