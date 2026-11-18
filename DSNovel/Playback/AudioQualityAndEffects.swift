import Foundation
import AVFoundation
import Observation

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

/// 五档音质选择（§3.2.1）：联动 BuiltinParserRuntime 多码率解析与 AVPlayerItem 前向缓冲时长
enum AudioQualityTier: String, CaseIterable, Identifiable, Codable, Sendable {
    case auto = "auto"
    case dataSaver = "dataSaver"
    case standard = "standard"
    case high = "high"
    case lossless = "lossless"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "智能自适应"
        case .dataSaver: return "省流"
        case .standard: return "标准"
        case .high: return "高清"
        case .lossless: return "臻享原声"
        }
    }

    var badgeText: String {
        switch self {
        case .auto: return "自适应"
        case .dataSaver: return "省流 32k"
        case .standard: return "标准 64k"
        case .high: return "HQ 128k"
        case .lossless: return "SQ 臻享"
        }
    }

    var subtitle: String {
        switch self {
        case .auto: return "Wi-Fi 下自动优选 128kbps 高清，移动网络下切换 64kbps 标准"
        case .dataSaver: return "约 12 MB/小时（M4A 24–32kbps），适合弱网与移动流量收听"
        case .standard: return "约 28 MB/小时（M4A/MP3 64kbps），清晰人声与流量平衡"
        case .high: return "约 56 MB/小时（AAC/M4A 128kbps），保留饱满演播细节与配乐"
        case .lossless: return "优先请求书源最高可用码率（最高 320kbps / 无损流），适合多人有声剧"
        }
    }

    nonisolated func parserQualityCode(isOnWiFi: Bool) -> String {
        switch self {
        case .auto: return isOnWiFi ? "M4A_128" : "M4A_64"
        case .dataSaver: return "M4A_24"
        case .standard: return "M4A_64"
        case .high, .lossless: return "M4A_128"
        }
    }

    nonisolated var preferredForwardBufferDuration: TimeInterval {
        switch self {
        case .dataSaver: return 6.0
        case .standard: return 15.0
        case .auto: return 15.0
        case .high: return 24.0
        case .lossless: return 30.0
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

/// 播放器音频处理管线：流媒体变调/响度补偿 + AVMutableAudioMix 增益 + 原生 5 段 AVAudioUnitEQ 构建
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
