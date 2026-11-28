import Accelerate
import AVFoundation
import Foundation
import os

/// AI 智能修音介入强度（控制单频段最大动态修正幅度）
public enum AudioSmartIntensity: String, Codable, Sendable, CaseIterable, Identifiable {
    case gentle
    case standard
    case strong

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .gentle: return "轻柔"
        case .standard: return "标准"
        case .strong: return "增强"
        }
    }

    public var maxCorrectionDB: Float {
        switch self {
        case .gentle: return 2.0
        case .standard: return 3.2
        case .strong: return 4.5
        }
    }
}

/// AI 智能修音实时遥测快照（供 UI 展示当前去闷 / 人声 / 齿音动态微调量）
public struct AudioSmartTelemetry: Sendable, Equatable {
    public let mudDB: Float
    public let voiceDB: Float
    public let sibilanceDB: Float
    public let isAnalyzing: Bool

    public init(mudDB: Float, voiceDB: Float, sibilanceDB: Float, isAnalyzing: Bool) {
        self.mudDB = mudDB
        self.voiceDB = voiceDB
        self.sibilanceDB = sibilanceDB
        self.isAnalyzing = isAnalyzing
    }

    public static let idle = AudioSmartTelemetry(mudDB: 0, voiceDB: 0, sibilanceDB: 0, isAnalyzing: false)
}

/// 逐帧 Pre-EQ 频谱分析器（Accelerate vDSP_fft，音频线程零阻塞零堆分配）
// SAFETY: 音频采样环形缓冲与 FFT 分析状态由锁与串行后台分析队列隔离。
final class AudioSmartAnalyzer: @unchecked Sendable {
    static let fftSize = 1024
    static let log2N: vDSP_Length = 10
    static let halfN = fftSize / 2
    private static let silenceRMSThreshold: Float = 0.004

    private struct StagingState {
        var ring: [Float]
        var writeIndex: Int = 0
        var validCount: Int = 0
        var samplesSinceAnalyze: Int = 0
        var sampleRate: Double = 44_100
        var intensity: AudioSmartIntensity = .standard
        var enabled: Bool = false
        var needsReset: Bool = false

        init() {
            self.ring = Array(repeating: 0, count: AudioSmartAnalyzer.fftSize)
        }
    }

    private let stagingLock = OSAllocatedUnfairLock(initialState: StagingState())
    private let workQueue = DispatchQueue(label: "com.dsnovel.app.audio.smartfft", qos: .utility)
    private let analyzeSource: DispatchSourceUserDataOr
    private let fftSetup: FFTSetup?
    let hannWindow: [Float]

    var workBuffer: [Float] = Array(repeating: 0, count: fftSize)
    var windowedBuffer: [Float] = Array(repeating: 0, count: fftSize)
    var splitReal: [Float] = Array(repeating: 0, count: halfN)
    var splitImag: [Float] = Array(repeating: 0, count: halfN)
    var magnitudes: [Float] = Array(repeating: 0, count: halfN)
    private var smoothedOffsets: [Float] = [0, 0, 0, 0, 0]
    private var lastTelemetryPushTime: CFAbsoluteTime = 0

    private let onResult: @Sendable ([Float], AudioSmartTelemetry, Bool) -> Void

    init(onResult: @escaping @Sendable ([Float], AudioSmartTelemetry, Bool) -> Void) {
        self.onResult = onResult
        self.fftSetup = vDSP_create_fftsetup(Self.log2N, FFTRadix(kFFTRadix2))
        var win = Array(repeating: Float(0), count: Self.fftSize)
        vDSP_hann_window(&win, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
        self.hannWindow = win

        let source = DispatchSource.makeUserDataOrSource(queue: workQueue)
        self.analyzeSource = source
        source.setEventHandler { [weak self] in
            self?.runAnalysisPass()
        }
        source.resume()
    }

    deinit {
        analyzeSource.cancel()
        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
        }
    }

    /// 音频渲染线程 Pre-EQ 采样入口：绝对不阻塞、不分配堆内存
    func capturePreEQSamples(
        _ bufferList: UnsafeMutablePointer<AudioBufferList>,
        frames: Int,
        isNonInterleaved: Bool,
        channels: Int,
        sampleRate: Double,
        intensity: AudioSmartIntensity
    ) {
        guard frames > 0 else { return }
        let abl = UnsafeMutableAudioBufferListPointer(bufferList)
        guard let firstBuf = abl.first, let mData = firstBuf.mData else { return }

        let stride = isNonInterleaved ? 1 : max(1, channels)
        let requiredBytes = frames * stride * MemoryLayout<Float>.size
        guard Int(firstBuf.mDataByteSize) >= requiredBytes else { return }

        let samplesAddr = UInt(bitPattern: mData)
        let hopSamples = max(2048, Int(sampleRate * 0.15))

        let shouldTrigger: Bool = stagingLock.withLockIfAvailable { state in
            guard let samples = UnsafePointer<Float>(bitPattern: samplesAddr) else { return false }
            state.enabled = true
            state.sampleRate = sampleRate
            state.intensity = intensity
            let copyCount = min(frames, Self.fftSize)
            let startOffset = frames - copyCount
            var wIdx = state.writeIndex
            for i in 0..<copyCount {
                let raw = samples[(startOffset + i) * stride]
                state.ring[wIdx] = raw.isFinite ? raw : 0
                wIdx += 1
                if wIdx == Self.fftSize { wIdx = 0 }
            }
            state.writeIndex = wIdx
            state.validCount = min(Self.fftSize, state.validCount + copyCount)
            state.samplesSinceAnalyze += frames
            if state.validCount >= Self.fftSize && state.samplesSinceAnalyze >= hopSamples {
                state.samplesSinceAnalyze = 0
                return true
            }
            return false
        } ?? false

        if shouldTrigger {
            analyzeSource.or(data: 1)
        }
    }

    /// 音频线程安全重置标记（供 unprepare 回调使用，零阻塞零堆分配）
    func markResetPendingOnAudioThread() {
        let didMark: Bool = stagingLock.withLockIfAvailable { state in
            state.needsReset = true
            state.writeIndex = 0
            state.validCount = 0
            state.samplesSinceAnalyze = 0
            return true
        } ?? false
        if didMark {
            analyzeSource.or(data: 1)
        }
    }

    /// 离音频线程立即清零历史状态（关闭智能修音或销毁上下文时调用）
    func reset() {
        stagingLock.withLock { state in
            state.enabled = false
            state.needsReset = false
            state.writeIndex = 0
            state.validCount = 0
            state.samplesSinceAnalyze = 0
            for i in state.ring.indices { state.ring[i] = 0 }
        }
        workQueue.async { [weak self] in
            guard let self else { return }
            self.smoothedOffsets = [0, 0, 0, 0, 0]
            self.lastTelemetryPushTime = 0
            self.onResult([0, 0, 0, 0, 0], .idle, true)
        }
    }

    /// 白盒离线测试入口：直接对指定单声道 PCM 窗口运行完整 FFT 频谱诊断并返回 5 段偏移与遥测
    internal func analyzeOfflineWindowForTesting(
        samples: [Float],
        sampleRate: Double,
        intensity: AudioSmartIntensity
    ) -> (offsets: [Float], telemetry: AudioSmartTelemetry) {
        guard let fftSetup else { return ([0, 0, 0, 0, 0], .idle) }
        for i in 0..<Self.fftSize {
            let v = i < samples.count ? samples[i] : 0
            workBuffer[i] = v.isFinite ? v : 0
        }
        var rms: Float = 0
        vDSP_rmsqv(workBuffer, 1, &rms, vDSP_Length(Self.fftSize))
        guard rms >= Self.silenceRMSThreshold else {
            return ([0, 0, 0, 0, 0], .idle)
        }
        let offsets = computeSpectralTargets(fftSetup: fftSetup, sampleRate: sampleRate, intensity: intensity)
        let telemetry = AudioSmartTelemetry(
            mudDB: (((offsets[0] + offsets[1]) * 0.5) * 10).rounded() / 10,
            voiceDB: (((offsets[2] + offsets[3]) * 0.5) * 10).rounded() / 10,
            sibilanceDB: (offsets[4] * 10).rounded() / 10,
            isAnalyzing: true
        )
        return (offsets, telemetry)
    }

    private func runAnalysisPass() {
        guard let fftSetup else { return }
        let snapshot: (enabled: Bool, needsReset: Bool, hasWindow: Bool, sampleRate: Double, intensity: AudioSmartIntensity) = stagingLock.withLock { state in
            if state.needsReset {
                state.needsReset = false
                for i in state.ring.indices { state.ring[i] = 0 }
                return (state.enabled, true, false, state.sampleRate, state.intensity)
            }
            guard state.enabled, state.validCount >= Self.fftSize else {
                return (state.enabled, false, false, state.sampleRate, state.intensity)
            }
            let tailCount = Self.fftSize - state.writeIndex
            for i in 0..<tailCount {
                workBuffer[i] = state.ring[state.writeIndex + i]
            }
            for i in 0..<state.writeIndex {
                workBuffer[tailCount + i] = state.ring[i]
            }
            return (state.enabled, false, true, state.sampleRate, state.intensity)
        }

        if snapshot.needsReset {
            smoothedOffsets = [0, 0, 0, 0, 0]
            lastTelemetryPushTime = 0
            onResult([0, 0, 0, 0, 0], .idle, true)
            return
        }
        guard snapshot.enabled, snapshot.hasWindow else { return }

        var rms: Float = 0
        vDSP_rmsqv(workBuffer, 1, &rms, vDSP_Length(Self.fftSize))

        let targetOffsets: [Float]
        let isSpeechActive = rms >= Self.silenceRMSThreshold
        if isSpeechActive {
            targetOffsets = computeSpectralTargets(
                fftSetup: fftSetup,
                sampleRate: snapshot.sampleRate,
                intensity: snapshot.intensity
            )
        } else {
            targetOffsets = [0, 0, 0, 0, 0]
        }

        let alpha: Float = isSpeechActive ? 0.25 : 0.14
        for i in 0..<5 {
            let next = smoothedOffsets[i] + (targetOffsets[i] - smoothedOffsets[i]) * alpha
            smoothedOffsets[i] = next.isFinite ? next : 0
        }

        let now = CFAbsoluteTimeGetCurrent()
        let mudDisplay = (smoothedOffsets[0] + smoothedOffsets[1]) * 0.5
        let voiceDisplay = (smoothedOffsets[2] + smoothedOffsets[3]) * 0.5
        let sibDisplay = smoothedOffsets[4]
        let telemetry = AudioSmartTelemetry(
            mudDB: (mudDisplay * 10).rounded() / 10,
            voiceDB: (voiceDisplay * 10).rounded() / 10,
            sibilanceDB: (sibDisplay * 10).rounded() / 10,
            isAnalyzing: isSpeechActive
        )

        let shouldEmitTelemetry = (now - lastTelemetryPushTime >= 0.22) || !isSpeechActive
        if shouldEmitTelemetry {
            lastTelemetryPushTime = now
        }
        onResult(smoothedOffsets, telemetry, shouldEmitTelemetry)
    }
}
