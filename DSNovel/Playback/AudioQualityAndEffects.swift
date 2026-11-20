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

/// 音质档位（4 档全局 + 「无损·最高音质」仅在解析器参与时出现；`lossless` 为旧存档兼容值）
///
/// 档位 → 各链码的映射集中在 `QualityPolicy`，本类型只负责展示与本地缓冲策略。
enum AudioQualityTier: String, CaseIterable, Identifiable, Codable, Sendable {
    case auto = "auto"
    case dataSaver = "dataSaver"
    case standard = "standard"
    case high = "high"
    /// 无损 · 最高音质（仅在「内置解析」参与解析的章节可选；解析器侧按 FLAC_24 → FLAC_16 回落）
    case losslessHQ = "losslessHQ"
    /// 旧存档兼容值：历史上等价于高清，继续折叠到 `.high`
    case lossless = "lossless"

    /// 全局默认档位（「我的 → 听书」与设置默认值使用；不含仅解析器可用的无损档）
    static let visibleTiers: [AudioQualityTier] = [.auto, .dataSaver, .standard, .high]

    var id: String { rawValue }

    nonisolated var normalizedForSelection: AudioQualityTier {
        self == .lossless ? .high : self
    }

    var title: String {
        switch self {
        case .auto: return "智能自适应"
        case .dataSaver: return "省流"
        case .standard: return "标准"
        case .high: return "高清"
        case .losslessHQ: return "无损 · 最高音质"
        case .lossless: return "高清"
        }
    }

    var badgeText: String {
        switch self {
        case .auto: return "自适应"
        case .dataSaver: return "省流·32k"
        case .standard: return "标准·64k"
        case .high, .lossless: return "高清·128k"
        case .losslessHQ: return "无损·最高"
        }
    }

    nonisolated func effectiveBadgeText(isOnWiFi: Bool) -> String {
        switch self {
        case .auto: return isOnWiFi ? "自适应·128k" : "自适应·64k"
        case .dataSaver: return "省流·32k"
        case .standard: return "标准·64k"
        case .high, .lossless: return "高清·128k"
        case .losslessHQ: return "无损·最高"
        }
    }

    /// 将播放器实际检测到的码率（kbps）归一并格式化为统一音质标签（如「省流·32k」「标准·64k」「高清·128k」）
    nonisolated static func badgeText(forDetectedBitrateKbps rawKbps: Int) -> String {
        let normalized = normalizedBitrateKbps(rawKbps)
        let tierPrefix: String
        if normalized <= 40 {
            tierPrefix = "省流"
        } else if normalized < 96 {
            tierPrefix = "标准"
        } else if normalized >= 320 {
            tierPrefix = "无损"
        } else {
            tierPrefix = "高清"
        }
        return "\(tierPrefix)·\(normalized)k"
    }

    nonisolated static func normalizedBitrateKbps(_ rawKbps: Int) -> Int {
        let clamped = max(16, rawKbps)
        let standards = [24, 32, 48, 64, 96, 128, 192, 256, 320]
        if let nearest = standards.min(by: { abs($0 - clamped) < abs($1 - clamped) }),
           Double(abs(nearest - clamped)) / Double(nearest) <= 0.16 {
            return nearest
        }
        return clamped
    }

    var subtitle: String {
        switch self {
        case .auto: return "Wi-Fi 下优选高清，移动网络下自动切换更省流的一档"
        case .dataSaver: return "约 12 MB/小时，适合弱网与移动流量收听（内置解析下按 48k 提供）"
        case .standard: return "约 28 MB/小时，清晰人声与流量占用平衡（内置解析下按 48k 提供）"
        case .high: return "约 56 MB/小时，保留饱满演播细节与配乐"
        case .losslessHQ: return "无损/最高音质，体积明显更大，需账号具备对应权限且专辑真的提供"
        case .lossless: return "约 56 MB/小时，保留饱满演播细节与配乐"
        }
    }

    nonisolated var preferredForwardBufferDuration: TimeInterval {
        switch self {
        case .dataSaver: return 6.0
        case .standard: return 15.0
        case .auto: return 15.0
        case .high, .lossless: return 24.0
        case .losslessHQ: return 24.0
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

// MARK: - MTAudioProcessingTap 实时 5 段 vDSP 双二阶 EQ + 声道平衡 + 软限幅器

final class AudioTapDSPContext: @unchecked Sendable {
    private struct Params: Equatable {
        var b0: Double = 0.0
        var b1: Double = 0.0
        var b2: Double = 0.0
        var b3: Double = 0.0
        var b4: Double = 0.0
        var balance: Double = 0.0
        var mixGain: Float = 1.0
        var generation: UInt64 = 1
    }

    private let lock = OSAllocatedUnfairLock(initialState: Params())

    // 音频渲染线程私有状态（仅在 prepare / process / unprepare 回调访问）
    private var sampleRate: Double = 44100.0
    private var isFloatFormat: Bool = true
    private var isNonInterleaved: Bool = true
    private var channelsPerFrame: UInt32 = 2
    private var appliedGeneration: UInt64 = 0
    private var eqActive: Bool = false
    private var biquadSetup: vDSP_biquad_Setup?
    private var delayBuffers: [[Float]] = []
    private var scratchBuffer: [Float] = []
    private nonisolated(unsafe) var coeffScratch: UnsafeMutablePointer<Double> = {
        let p = UnsafeMutablePointer<Double>.allocate(capacity: 25)
        p.initialize(repeating: 0.0, count: 25)
        return p
    }()

    nonisolated init(bandsDb: [Double], balance: Double, mixGain: Float) {
        update(bandsDb: bandsDb, balance: balance, mixGain: mixGain)
    }

    deinit {
        destroyBiquad()
        coeffScratch.deinitialize(count: 25)
        coeffScratch.deallocate()
    }

    nonisolated func update(bandsDb: [Double], balance: Double, mixGain: Float) {
        let n0 = min(max(0 < bandsDb.count ? bandsDb[0] : 0.0, -12.0), 12.0)
        let n1 = min(max(1 < bandsDb.count ? bandsDb[1] : 0.0, -12.0), 12.0)
        let n2 = min(max(2 < bandsDb.count ? bandsDb[2] : 0.0, -12.0), 12.0)
        let n3 = min(max(3 < bandsDb.count ? bandsDb[3] : 0.0, -12.0), 12.0)
        let n4 = min(max(4 < bandsDb.count ? bandsDb[4] : 0.0, -12.0), 12.0)
        let clampedBalance = min(max(balance, -1.0), 1.0)
        let clampedGain = min(max(mixGain, 0.0), 4.0)
        lock.withLock { state in
            if state.b0 != n0 || state.b1 != n1 || state.b2 != n2 || state.b3 != n3 || state.b4 != n4 {
                state.b0 = n0
                state.b1 = n1
                state.b2 = n2
                state.b3 = n3
                state.b4 = n4
                state.generation &+= 1
            }
            state.balance = clampedBalance
            state.mixGain = clampedGain
        }
    }

    fileprivate nonisolated func prepare(format: AudioStreamBasicDescription, maxFrames: CMItemCount) {
        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 44100.0
        isFloatFormat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        isNonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        channelsPerFrame = max(1, format.mChannelsPerFrame)
        appliedGeneration = 0
        let chCount = Int(max(2, channelsPerFrame))
        let delayLen = 2 * 5 + 2
        delayBuffers = Array(repeating: [Float](repeating: 0, count: delayLen), count: chCount)
        let cap = max(Int(maxFrames), 16384)
        scratchBuffer = [Float](repeating: 0, count: cap)
    }

    fileprivate nonisolated func unprepare() {
        destroyBiquad()
        delayBuffers.removeAll()
        scratchBuffer.removeAll()
        appliedGeneration = 0
    }

    private nonisolated func destroyBiquad() {
        if let setup = biquadSetup {
            vDSP_biquad_DestroySetup(setup)
            biquadSetup = nil
        }
    }

    private nonisolated func rebuildBiquadIfNeeded(params: Params) {
        guard params.generation != appliedGeneration else { return }
        appliedGeneration = params.generation
        let hasActiveBand = abs(params.b0) >= 0.05
            || abs(params.b1) >= 0.05
            || abs(params.b2) >= 0.05
            || abs(params.b3) >= 0.05
            || abs(params.b4) >= 0.05
        eqActive = hasActiveBand
        destroyBiquad()
        guard hasActiveBand else { return }

        Self.writeFiveBandBiquadCoefficients(
            b0: params.b0, b1: params.b1, b2: params.b2, b3: params.b3, b4: params.b4,
            sampleRate: sampleRate,
            into: coeffScratch
        )
        biquadSetup = vDSP_biquad_CreateSetup(coeffScratch, vDSP_Length(5))
        for i in delayBuffers.indices {
            for j in delayBuffers[i].indices {
                delayBuffers[i][j] = 0
            }
        }
    }

    /// 计算 5 段双二阶滤波器系数（100Hz Low-Shelf / 330Hz, 1kHz, 3.3kHz Peaking / 10kHz High-Shelf）
    /// 返回 25 个 Double，每段顺序为 [b0, b1, b2, a1, a2]（符合 vDSP_biquad_CreateSetup 约定）
    nonisolated static func writeFiveBandBiquadCoefficients(
        b0: Double, b1: Double, b2: Double, b3: Double, b4: Double,
        sampleRate: Double,
        into out: UnsafeMutablePointer<Double>
    ) {
        let fs = max(8000.0, sampleRate)
        let freqs: (Double, Double, Double, Double, Double) = (100, 330, 1000, 3300, 10000)
        for idx in 0..<5 {
            let rawDb: Double = idx == 0 ? b0 : (idx == 1 ? b1 : (idx == 2 ? b2 : (idx == 3 ? b3 : b4)))
            let db = min(max(rawDb, -12.0), 12.0)
            let base = idx * 5
            if abs(db) < 0.05 {
                out[base + 0] = 1.0
                out[base + 1] = 0.0
                out[base + 2] = 0.0
                out[base + 3] = 0.0
                out[base + 4] = 0.0
                continue
            }
            let rawFreq: Double = idx == 0 ? freqs.0 : (idx == 1 ? freqs.1 : (idx == 2 ? freqs.2 : (idx == 3 ? freqs.3 : freqs.4)))
            let freq = min(rawFreq, fs * 0.45)
            let w0 = 2.0 * Double.pi * freq / fs
            let cosW0 = cos(w0)
            let sinW0 = sin(w0)
            let aAmp = pow(10.0, db / 40.0)
            let cb0, cb1, cb2, ca0, ca1, ca2: Double
            if idx == 0 {
                let alpha = sinW0 / 2.0 * sqrt(2.0)
                let twoSqrtAAlpha = 2.0 * sqrt(aAmp) * alpha
                cb0 = aAmp * ((aAmp + 1.0) - (aAmp - 1.0) * cosW0 + twoSqrtAAlpha)
                cb1 = 2.0 * aAmp * ((aAmp - 1.0) - (aAmp + 1.0) * cosW0)
                cb2 = aAmp * ((aAmp + 1.0) - (aAmp - 1.0) * cosW0 - twoSqrtAAlpha)
                ca0 = (aAmp + 1.0) + (aAmp - 1.0) * cosW0 + twoSqrtAAlpha
                ca1 = -2.0 * ((aAmp - 1.0) + (aAmp + 1.0) * cosW0)
                ca2 = (aAmp + 1.0) + (aAmp - 1.0) * cosW0 - twoSqrtAAlpha
            } else if idx == 4 {
                let alpha = sinW0 / 2.0 * sqrt(2.0)
                let twoSqrtAAlpha = 2.0 * sqrt(aAmp) * alpha
                cb0 = aAmp * ((aAmp + 1.0) + (aAmp - 1.0) * cosW0 + twoSqrtAAlpha)
                cb1 = -2.0 * aAmp * ((aAmp - 1.0) + (aAmp + 1.0) * cosW0)
                cb2 = aAmp * ((aAmp + 1.0) + (aAmp - 1.0) * cosW0 - twoSqrtAAlpha)
                ca0 = (aAmp + 1.0) - (aAmp - 1.0) * cosW0 + twoSqrtAAlpha
                ca1 = 2.0 * ((aAmp - 1.0) - (aAmp + 1.0) * cosW0)
                ca2 = (aAmp + 1.0) - (aAmp - 1.0) * cosW0 - twoSqrtAAlpha
            } else {
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
            out[base + 0] = cb0 * invA0
            out[base + 1] = cb1 * invA0
            out[base + 2] = cb2 * invA0
            out[base + 3] = ca1 * invA0
            out[base + 4] = ca2 * invA0
        }
    }

    nonisolated static func computeFiveBandBiquadCoefficients(
        bandsDb: [Double],
        sampleRate: Double
    ) -> [Double] {
        let fs = max(8000.0, sampleRate)
        let specs = EqualizerBandSpec.standardFiveBands
        var coeffs: [Double] = []
        coeffs.reserveCapacity(specs.count * 5)

        for spec in specs {
            let db = spec.index < bandsDb.count ? min(max(bandsDb[spec.index], -12.0), 12.0) : 0.0
            if abs(db) < 0.05 {
                // 单位直通滤波器
                coeffs.append(contentsOf: [1.0, 0.0, 0.0, 0.0, 0.0])
                continue
            }
            let freq = min(Double(spec.frequencyHz), fs * 0.45)
            let w0 = 2.0 * Double.pi * freq / fs
            let cosW0 = cos(w0)
            let sinW0 = sin(w0)
            let aAmp = pow(10.0, db / 40.0)

            let b0: Double
            let b1: Double
            let b2: Double
            let a0: Double
            let a1: Double
            let a2: Double

            if spec.index == 0 {
                // Low-Shelf (S = 1.0)
                let alpha = sinW0 / 2.0 * sqrt(2.0)
                let twoSqrtAAlpha = 2.0 * sqrt(aAmp) * alpha
                b0 = aAmp * ((aAmp + 1.0) - (aAmp - 1.0) * cosW0 + twoSqrtAAlpha)
                b1 = 2.0 * aAmp * ((aAmp - 1.0) - (aAmp + 1.0) * cosW0)
                b2 = aAmp * ((aAmp + 1.0) - (aAmp - 1.0) * cosW0 - twoSqrtAAlpha)
                a0 = (aAmp + 1.0) + (aAmp - 1.0) * cosW0 + twoSqrtAAlpha
                a1 = -2.0 * ((aAmp - 1.0) + (aAmp + 1.0) * cosW0)
                a2 = (aAmp + 1.0) + (aAmp - 1.0) * cosW0 - twoSqrtAAlpha
            } else if spec.index == specs.count - 1 {
                // High-Shelf (S = 1.0)
                let alpha = sinW0 / 2.0 * sqrt(2.0)
                let twoSqrtAAlpha = 2.0 * sqrt(aAmp) * alpha
                b0 = aAmp * ((aAmp + 1.0) + (aAmp - 1.0) * cosW0 + twoSqrtAAlpha)
                b1 = -2.0 * aAmp * ((aAmp - 1.0) + (aAmp + 1.0) * cosW0)
                b2 = aAmp * ((aAmp + 1.0) + (aAmp - 1.0) * cosW0 - twoSqrtAAlpha)
                a0 = (aAmp + 1.0) - (aAmp - 1.0) * cosW0 + twoSqrtAAlpha
                a1 = 2.0 * ((aAmp - 1.0) - (aAmp + 1.0) * cosW0)
                a2 = (aAmp + 1.0) - (aAmp - 1.0) * cosW0 - twoSqrtAAlpha
            } else {
                // Peaking EQ (Q = 1.414, ~1 octave bandwidth)
                let q = 1.41421356
                let alpha = sinW0 / (2.0 * q)
                b0 = 1.0 + alpha * aAmp
                b1 = -2.0 * cosW0
                b2 = 1.0 - alpha * aAmp
                a0 = 1.0 + alpha / aAmp
                a1 = -2.0 * cosW0
                a2 = 1.0 - alpha / aAmp
            }

            let invA0 = abs(a0) > 1e-12 ? (1.0 / a0) : 1.0
            coeffs.append(b0 * invA0)
            coeffs.append(b1 * invA0)
            coeffs.append(b2 * invA0)
            coeffs.append(a1 * invA0)
            coeffs.append(a2 * invA0)
        }
        return coeffs
    }

    fileprivate nonisolated func process(
        frameCount: Int,
        bufferListInOut: UnsafeMutablePointer<AudioBufferList>
    ) {
        guard isFloatFormat, frameCount > 0 else { return }
        let params = lock.withLock { $0 }
        rebuildBiquadIfNeeded(params: params)

        let balance = params.balance
        let leftPan: Float = balance <= 0 ? 1.0 : Float(max(0.0, 1.0 - balance))
        let rightPan: Float = balance >= 0 ? 1.0 : Float(max(0.0, 1.0 + balance))
        let baseGain = params.mixGain
        let needsGainOrLimit = eqActive || abs(baseGain - 1.0) > 0.001 || abs(balance) > 0.001

        guard needsGainOrLimit else { return }

        let abl = UnsafeMutableAudioBufferListPointer(bufferListInOut)
        if isNonInterleaved {
            for bufIdx in 0..<abl.count {
                guard let rawData = abl[bufIdx].mData else { continue }
                let samples = rawData.assumingMemoryBound(to: Float.self)
                let count = min(frameCount, Int(abl[bufIdx].mDataByteSize) / MemoryLayout<Float>.size)
                guard count > 0 else { continue }

                if eqActive, let setup = biquadSetup, bufIdx < delayBuffers.count {
                    if scratchBuffer.count < count {
                        scratchBuffer = [Float](repeating: 0, count: count)
                    }
                    delayBuffers[bufIdx].withUnsafeMutableBufferPointer { delayPtr in
                        scratchBuffer.withUnsafeMutableBufferPointer { dstPtr in
                            guard let dBase = delayPtr.baseAddress, let sBase = dstPtr.baseAddress else { return }
                            vDSP_biquad(setup, dBase, samples, 1, sBase, 1, vDSP_Length(count))
                            samples.update(from: sBase, count: count)
                        }
                    }
                }

                let panGain: Float = {
                    if abl.count >= 2 {
                        return bufIdx == 0 ? leftPan : (bufIdx == 1 ? rightPan : 1.0)
                    }
                    return 1.0
                }()
                let totalGain = baseGain * panGain
                Self.applyGainAndSoftLimiter(samples: samples, count: count, gain: totalGain, enableLimiter: totalGain > 1.01 || eqActive)
            }
        } else if abl.count == 1, let rawData = abl[0].mData {
            // Interleaved PCM (e.g., stereo L,R,L,R)
            let chCount = Int(max(1, abl[0].mNumberChannels))
            let totalSamples = min(frameCount * chCount, Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size)
            let actualFrames = totalSamples / chCount
            guard actualFrames > 0 else { return }
            let samples = rawData.assumingMemoryBound(to: Float.self)

            for ch in 0..<chCount {
                if eqActive, let setup = biquadSetup, ch < delayBuffers.count {
                    if scratchBuffer.count < actualFrames {
                        scratchBuffer = [Float](repeating: 0, count: actualFrames)
                    }
                    let chPtr = samples.advanced(by: ch)
                    delayBuffers[ch].withUnsafeMutableBufferPointer { delayPtr in
                        scratchBuffer.withUnsafeMutableBufferPointer { dstPtr in
                            guard let dBase = delayPtr.baseAddress, let sBase = dstPtr.baseAddress else { return }
                            vDSP_biquad(setup, dBase, chPtr, vDSP_Stride(chCount), sBase, 1, vDSP_Length(actualFrames))
                            for i in 0..<actualFrames {
                                chPtr[i * chCount] = sBase[i]
                            }
                        }
                    }
                }

                let panGain: Float = {
                    if chCount >= 2 {
                        return ch == 0 ? leftPan : (ch == 1 ? rightPan : 1.0)
                    }
                    return 1.0
                }()
                let totalGain = baseGain * panGain
                let enableLimiter = totalGain > 1.01 || eqActive
                for i in 0..<actualFrames {
                    let idx = i * chCount + ch
                    let scaled = samples[idx] * totalGain
                    samples[idx] = enableLimiter ? Self.softLimitSample(scaled) : scaled
                }
            }
        }
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

/// 播放器音频处理管线：流媒体变调/响度补偿 + MTAudioProcessingTap 5 段 vDSP EQ / 声道平衡 / 软限幅器
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

    nonisolated static func isHLSAsset(_ asset: AVAsset) -> Bool {
        guard let urlAsset = asset as? AVURLAsset else { return false }
        let url = urlAsset.url
        if url.isFileURL { return false }
        let ext = url.pathExtension.lowercased()
        let absLower = url.absoluteString.lowercased()
        return ext == "m3u8" || absLower.contains(".m3u8")
    }

    nonisolated static func applyToPlayerItem(
        _ item: AVPlayerItem,
        preset: AudioEffectPreset,
        audioChannel: AudioChannelMode,
        bookVolume: Double,
        eqBandsDb: [Double],
        boostDB: Double = 0.0,
        balance: Double = 0.0,
        qualityTier: AudioQualityTier = .high
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

    /// 构建接入 `MTAudioProcessingTap` 的 `AVAudioMix`（5 段 vDSP 双二阶 EQ + 声道平衡 + 软限幅器）
    /// 对 HLS `.m3u8` 或无音轨资源返回 `nil`。
    nonisolated static func makeAudioTapMix(
        for asset: AVAsset,
        context: AudioTapDSPContext
    ) async -> AVAudioMix? {
        guard !isHLSAsset(asset) else { return nil }
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
