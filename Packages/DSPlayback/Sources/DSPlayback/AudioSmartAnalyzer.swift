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
final class AudioSmartAnalyzer: @unchecked Sendable {
    static let fftSize = 1024
    private static let log2N: vDSP_Length = 10
    private static let halfN = fftSize / 2
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
    private let hannWindow: [Float]

    private var workBuffer: [Float] = Array(repeating: 0, count: fftSize)
    private var windowedBuffer: [Float] = Array(repeating: 0, count: fftSize)
    private var splitReal: [Float] = Array(repeating: 0, count: halfN)
    private var splitImag: [Float] = Array(repeating: 0, count: halfN)
    private var magnitudes: [Float] = Array(repeating: 0, count: halfN)
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

        let samples = mData.assumingMemoryBound(to: Float.self)
        let hopSamples = max(2048, Int(sampleRate * 0.15))

        let shouldTrigger: Bool = stagingLock.withLockIfAvailable { state in
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

    private func computeSpectralTargets(
        fftSetup: FFTSetup,
        sampleRate: Double,
        intensity: AudioSmartIntensity
    ) -> [Float] {
        let safeRate = max(8_000, sampleRate)
        vDSP_vmul(workBuffer, 1, hannWindow, 1, &windowedBuffer, 1, vDSP_Length(Self.fftSize))

        splitReal.withUnsafeMutableBufferPointer { realPtr in
            splitImag.withUnsafeMutableBufferPointer { imagPtr in
                guard let rBase = realPtr.baseAddress, let iBase = imagPtr.baseAddress else { return }
                var split = DSPSplitComplex(realp: rBase, imagp: iBase)
                windowedBuffer.withUnsafeBufferPointer { buf in
                    buf.withMemoryRebound(to: DSPComplex.self) { complexBuf in
                        guard let complexPtr = complexBuf.baseAddress else { return }
                        vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(Self.halfN))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, Self.log2N, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(Self.halfN))
            }
        }

        let binHz = max(1.0, safeRate / Double(Self.fftSize))
        let dbLowMud = bandPowerDB(minHz: 70, maxHz: 200, sampleRate: safeRate, binHz: binHz)
        let dbBoxiness = bandPowerDB(minHz: 200, maxHz: 500, sampleRate: safeRate, binHz: binHz)
        let dbVoiceMid = bandPowerDB(minHz: 700, maxHz: 1800, sampleRate: safeRate, binHz: binHz)
        let dbVoicePres = bandPowerDB(minHz: 1800, maxHz: 4200, sampleRate: safeRate, binHz: binHz)

        let voiceRef = (dbVoiceMid + dbVoicePres) * 0.5
        let limit = intensity.maxCorrectionDB
        let scale = limit / 3.2

        let lowExcess = (dbLowMud - voiceRef) - 3.0
        let cut100 = lowExcess > 0 ? -min(limit, lowExcess * 0.35 * scale) : 0

        let boxExcess = (dbBoxiness - voiceRef) - 2.5
        let cut300 = boxExcess > 0 ? -min(limit * 0.85, boxExcess * 0.32 * scale) : 0

        let claritySlope = dbVoicePres - dbVoiceMid
        let lift1k: Float
        let lift3k2: Float
        if claritySlope < -4.5 {
            let deficit = (-4.5 - claritySlope)
            lift1k = min(limit * 0.55, deficit * 0.18 * scale)
            lift3k2 = min(limit, deficit * 0.36 * scale)
        } else if claritySlope > 3.0 {
            let harsh = claritySlope - 3.0
            lift1k = 0
            lift3k2 = -min(limit * 0.65, harsh * 0.28 * scale)
        } else {
            lift1k = 0
            lift3k2 = 0
        }

        // 低采样率音源（<18kHz）8kHz 临近或超过奈奎斯特极限，跳过高频齿音修正
        let adjust8k: Float
        if safeRate >= 18_000 {
            let dbSibilance = bandPowerDB(minHz: 5000, maxHz: 10000, sampleRate: safeRate, binHz: binHz)
            let sibDelta = dbSibilance - voiceRef
            if sibDelta > -6.5 {
                adjust8k = -min(limit, (sibDelta + 6.5) * 0.38 * scale)
            } else if sibDelta < -22.0 {
                adjust8k = min(limit * 0.45, (-22.0 - sibDelta) * 0.14 * scale)
            } else {
                adjust8k = 0
            }
        } else {
            adjust8k = 0
        }

        return [
            clamp(cut100, limit: limit),
            clamp(cut300, limit: limit),
            clamp(lift1k, limit: limit),
            clamp(lift3k2, limit: limit),
            clamp(adjust8k, limit: limit)
        ]
    }

    private func bandPowerDB(minHz: Double, maxHz: Double, sampleRate: Double, binHz: Double) -> Float {
        guard minHz < sampleRate * 0.48 else { return -90.0 }
        let startBin = min(Self.halfN - 1, max(1, Int(floor(minHz / binHz))))
        let endBin = min(Self.halfN - 1, max(startBin, Int(ceil(min(maxHz, sampleRate * 0.49) / binHz))))
        var sum: Float = 0
        for bin in startBin...endBin {
            sum += magnitudes[bin]
        }
        let avg = sum / Float(endBin - startBin + 1)
        return 10.0 * log10f(max(avg, 1e-12))
    }

    private func clamp(_ value: Float, limit: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(limit, max(-limit, value))
    }
}
