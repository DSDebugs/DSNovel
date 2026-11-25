import Accelerate
import AVFoundation
import Foundation

/// AudioTapProcessor 底层 biquad 系数计算、实时 PCM 渲染与白盒离线单测扩展（拆分保持单文件 <= 385 行）
/// 实时 5 段 EQ + AI 智能修音 + 可调响度增强 + 防爆音动态均衡 DSP 参数快照（跨音频渲染线程只读传递）
public struct AudioDSPParameters: Sendable, Equatable {
    public let bandGainsDB: [Float] // 100, 300, 1000, 3200, 8000 Hz
    public let isCustomEQ: Bool
    public let stereoBalance: Float // -1.0 ... 1.0（保留兼容字段，默认 0）
    public let volumeBoostEnabled: Bool
    public let volumeBoostDB: Float // 0.0 ... 9.0 dB
    public let dynamicLevelingEnabled: Bool
    public let smartRepairEnabled: Bool
    public let smartRepairIntensity: AudioSmartIntensity
    public let fadeGain: Float      // 0.0 ... 1.0

    public init(
        bandGainsDB: [Float] = [0, 0, 0, 0, 0],
        isCustomEQ: Bool = false,
        stereoBalance: Float = 0,
        volumeBoostEnabled: Bool = false,
        volumeBoostDB: Float = 0,
        dynamicLevelingEnabled: Bool = false,
        smartRepairEnabled: Bool = false,
        smartRepairIntensity: AudioSmartIntensity = .standard,
        fadeGain: Float = 1.0
    ) {
        self.bandGainsDB = bandGainsDB.count == 5 ? bandGainsDB : [0, 0, 0, 0, 0]
        self.isCustomEQ = isCustomEQ
        self.stereoBalance = max(-1, min(1, stereoBalance))
        let resolvedDB: Float = volumeBoostDB > 0.01 ? min(9.0, max(0.0, volumeBoostDB)) : (volumeBoostEnabled ? 2.0 : 0.0)
        self.volumeBoostDB = resolvedDB
        self.volumeBoostEnabled = resolvedDB > 0.05
        self.dynamicLevelingEnabled = dynamicLevelingEnabled
        self.smartRepairEnabled = smartRepairEnabled
        self.smartRepairIntensity = smartRepairIntensity
        self.fadeGain = max(0, min(1, fadeGain))
    }

    public var needsProcessing: Bool {
        smartRepairEnabled
            || volumeBoostDB > 0.05
            || dynamicLevelingEnabled
            || abs(stereoBalance) > 0.01
            || fadeGain < 0.999
            || bandGainsDB.contains(where: { abs($0) > 0.05 })
    }

    /// 合并静态风格 EQ 与 AI 智能修音动态偏移（预设风格正向增益适度收敛以防同向过冲），并执行 [-10, +10] dB 联合限幅
    public static func combinedBandGains(
        staticBands: [Float],
        smartOffsets: [Float],
        smartEnabled: Bool,
        isCustomEQ: Bool = false
    ) -> [Float] {
        guard smartEnabled, staticBands.count == 5, smartOffsets.count == 5 else {
            return staticBands.count == 5 ? staticBands : [0, 0, 0, 0, 0]
        }
        var out: [Float] = []
        out.reserveCapacity(5)
        for i in 0..<5 {
            let base = (!isCustomEQ && staticBands[i] > 0) ? (staticBands[i] * 0.85) : staticBands[i]
            let sum = base + smartOffsets[i]
            let safe = sum.isFinite ? min(10.0, max(-10.0, sum)) : 0
            out.append(safe)
        }
        return out
    }

    /// EQ 正向能量自动电平补偿（保持切换音色风格或开启智能修音时主观响度平稳）
    public static func eqMakeupLinearGain(for bands: [Float]) -> Float {
        guard !bands.isEmpty else { return 1.0 }
        let avgPositive = bands.reduce(Float(0)) { $0 + max(0, $1) } / Float(bands.count)
        guard avgPositive > 0.05 else { return 1.0 }
        let trimDB = max(-2.5, -0.35 * avgPositive)
        return powf(10.0, trimDB / 20.0)
    }

    /// 防爆音动态均衡最大正向抬升上限随响度增强档位联动收敛，避免串联过推入软削波区
    public static func maxDynamicUpGain(forVolumeBoostDB boostDB: Float) -> Float {
        max(1.18, 2.0 - max(0, boostDB) * 0.08)
    }

    public static let centerFrequencies: [Double] = [100, 300, 1000, 3200, 8000]
}


extension AudioTapProcessor {
    struct FormatState: Sendable {
        var isFloat32: Bool = true
        var isNonInterleaved: Bool = true
        var channelsPerFrame: Int = 2
        var needsDelayReset: Bool = false
    }

    final class RenderSnapshot: @unchecked Sendable {
        let params: AudioDSPParameters
        let biquad: BiquadHolder

        init(params: AudioDSPParameters, biquad: BiquadHolder) {
            self.params = params
            self.biquad = biquad
        }
    }

    final class BiquadHolder: @unchecked Sendable {
        let setup: vDSP_biquad_Setup?
        let sampleRate: Double
        let gainsDB: [Float]

        init(gainsDB: [Float], sampleRate: Double) {
            self.gainsDB = gainsDB
            self.sampleRate = max(8_000, sampleRate)
            let coeffs = Self.computePeakingCoefficients(gainsDB: gainsDB, sampleRate: self.sampleRate)
            self.setup = vDSP_biquad_CreateSetup(coeffs, vDSP_Length(AudioDSPParameters.centerFrequencies.count))
        }

        deinit {
            if let s = setup { vDSP_biquad_DestroySetup(s) }
        }

        static func computePeakingCoefficients(gainsDB: [Float], sampleRate: Double) -> [Double] {
            let sr = max(8_000, sampleRate)
            var out: [Double] = []
            out.reserveCapacity(gainsDB.count * 5)
            for (idx, gainDB) in gainsDB.enumerated() {
                let f0 = AudioDSPParameters.centerFrequencies[idx]
                let a = pow(10.0, Double(gainDB) / 40.0)
                let w0 = 2.0 * Double.pi * min(f0, sr * 0.45) / sr
                let alpha = sin(w0) / 1.7
                let cosW0 = cos(w0)
                let b0 = 1.0 + alpha * a, b1 = -2.0 * cosW0, b2 = 1.0 - alpha * a
                let a0 = 1.0 + alpha / a, a1 = -2.0 * cosW0, a2 = 1.0 - alpha / a
                out.append(contentsOf: [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0])
            }
            return out
        }
    }

    static func processAudioBufferList(
        _ bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
        frames: Int,
        format: FormatState,
        params: AudioDSPParameters,
        setup: vDSP_biquad_Setup?,
        delayLeft: inout [Float],
        delayRight: inout [Float],
        levelingGain: inout Float
    ) -> Bool {
        let boostLinear: Float = params.volumeBoostDB > 0.05 ? powf(10.0, params.volumeBoostDB / 20.0) : 1.0
        let eqTrim = AudioDSPParameters.eqMakeupLinearGain(for: params.bandGainsDB)
        let baseGain = params.fadeGain * boostLinear * eqTrim
        let leftGain = baseGain * (params.stereoBalance > 0 ? (1.0 - params.stereoBalance) : 1.0)
        let rightGain = baseGain * (params.stereoBalance < 0 ? (1.0 + params.stereoBalance) : 1.0)
        let abl = UnsafeMutableAudioBufferListPointer(bufferListInOut)

        if format.isNonInterleaved {
            var detectedNonFinite = false
            let isMono = abl.count == 1
            let requiredBytes = frames * MemoryLayout<Float>.size
            for (chIdx, buf) in abl.enumerated() {
                guard let mData = buf.mData, Int(buf.mDataByteSize) >= requiredBytes else { continue }
                let samples = mData.assumingMemoryBound(to: Float.self)
                if sanitizeNonFiniteInputs(samples, count: frames) {
                    detectedNonFinite = true
                }
                if let s = setup {
                    if chIdx == 0 {
                        vDSP_biquad(s, &delayLeft, samples, 1, samples, 1, vDSP_Length(frames))
                    } else if chIdx == 1 {
                        vDSP_biquad(s, &delayRight, samples, 1, samples, 1, vDSP_Length(frames))
                    }
                }
                if params.dynamicLevelingEnabled && chIdx == 0 {
                    updateDynamicLevelingGain(samples: samples, count: frames, stride: 1, maxUpGain: AudioDSPParameters.maxDynamicUpGain(forVolumeBoostDB: params.volumeBoostDB), currentGain: &levelingGain)
                }
                var gain = (isMono ? baseGain : ((chIdx == 0) ? leftGain : rightGain)) * (params.dynamicLevelingEnabled ? levelingGain : 1.0)
                if abs(gain - 1.0) > 0.001 {
                    vDSP_vsmul(samples, 1, &gain, samples, 1, vDSP_Length(frames))
                }
                if sanitizeAndClip(samples, count: frames, stride: 1) {
                    detectedNonFinite = true
                }
            }
            return detectedNonFinite
        } else if let buf = abl.first, let mData = buf.mData {
            let channels = max(1, format.channelsPerFrame)
            if Int(buf.mDataByteSize) >= frames * channels * MemoryLayout<Float>.size {
                return processInterleavedPCM(
                    samples: mData.assumingMemoryBound(to: Float.self),
                    frames: frames,
                    channels: channels,
                    params: params,
                    setup: setup,
                    delayLeft: &delayLeft,
                    delayRight: &delayRight,
                    levelingGain: &levelingGain
                )
            }
        }
        return false
    }

    /// 供白盒单元测试离线下验证与实时回调完全一致的 biquad EQ / 增益 / 单声道保护 / 限幅 / NaN 防护逻辑
    internal func processOfflinePCMForTesting(samples: inout [Float], channelCount: Int, sampleRate: Double) {
        let channels = max(1, channelCount)
        let frames = samples.count / channels
        guard frames > 0 else { return }

        let (ctx, fallbackParams) = contextLock.withLock { (activeContext, latestParams) }
        let params = ctx?.currentSnapshot().params ?? fallbackParams
        let holder = BiquadHolder(gainsDB: params.bandGainsDB, sampleRate: sampleRate)
        var delayLeft: [Float] = Array(repeating: 0, count: 14)
        var delayRight: [Float] = Array(repeating: 0, count: 14)
        var levelingGain: Float = 1.0

        samples.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            _ = Self.processInterleavedPCM(
                samples: base, frames: frames, channels: channels,
                params: params, setup: holder.setup,
                delayLeft: &delayLeft, delayRight: &delayRight,
                levelingGain: &levelingGain
            )
        }
    }

    static func processInterleavedPCM(
        samples: UnsafeMutablePointer<Float>,
        frames: Int,
        channels: Int,
        params: AudioDSPParameters,
        setup: vDSP_biquad_Setup?,
        delayLeft: inout [Float],
        delayRight: inout [Float],
        levelingGain: inout Float
    ) -> Bool {
        let boostLinear: Float = params.volumeBoostDB > 0.05 ? powf(10.0, params.volumeBoostDB / 20.0) : 1.0
        let eqTrim = AudioDSPParameters.eqMakeupLinearGain(for: params.bandGainsDB)
        let baseGain = params.fadeGain * boostLinear * eqTrim
        let isMono = channels == 1
        let leftGain = isMono ? baseGain : baseGain * (params.stereoBalance > 0 ? (1.0 - params.stereoBalance) : 1.0)
        let rightGain = baseGain * (params.stereoBalance < 0 ? (1.0 + params.stereoBalance) : 1.0)
        let stride = vDSP_Stride(channels)
        let inputHadNonFinite = sanitizeNonFiniteInputs(samples, count: frames * channels)

        if let s = setup {
            vDSP_biquad(s, &delayLeft, samples, stride, samples, stride, vDSP_Length(frames))
            if channels >= 2 {
                let rightPtr = samples.advanced(by: 1)
                vDSP_biquad(s, &delayRight, rightPtr, stride, rightPtr, stride, vDSP_Length(frames))
            }
        }
        if params.dynamicLevelingEnabled {
            updateDynamicLevelingGain(samples: samples, count: frames, stride: Int(stride), maxUpGain: AudioDSPParameters.maxDynamicUpGain(forVolumeBoostDB: params.volumeBoostDB), currentGain: &levelingGain)
        }
        let dynFactor: Float = params.dynamicLevelingEnabled ? levelingGain : 1.0
        var lGain = leftGain * dynFactor
        if abs(lGain - 1.0) > 0.001 {
            vDSP_vsmul(samples, stride, &lGain, samples, stride, vDSP_Length(frames))
        }
        if channels >= 2 {
            let rightPtr = samples.advanced(by: 1)
            var rGain = rightGain * dynFactor
            if abs(rGain - 1.0) > 0.001 {
                vDSP_vsmul(rightPtr, stride, &rGain, rightPtr, stride, vDSP_Length(frames))
            }
        }
        let postNonFinite = sanitizeAndClip(samples, count: frames * channels, stride: 1)
        return inputHadNonFinite || postNonFinite
    }

    private static func sanitizeNonFiniteInputs(_ samples: UnsafeMutablePointer<Float>, count: Int) -> Bool {
        var found = false
        for i in 0..<count where !samples[i].isFinite {
            samples[i] = 0
            found = true
        }
        return found
    }

    /// 实时 RMS 包络软压缩器（防爆音动态均衡：快速压制突发巨响，温和抬升轻声旁白）
    private static func updateDynamicLevelingGain(
        samples: UnsafeMutablePointer<Float>,
        count: Int,
        stride: Int,
        maxUpGain: Float,
        currentGain: inout Float
    ) {
        guard count > 0 else { return }
        var sumSq: Float = 0
        for i in 0..<count {
            let v = samples[i * stride]
            if v.isFinite { sumSq += v * v }
        }
        let rms = sqrtf(sumSq / Float(count))
        guard rms > 0.004 else {
            currentGain += (1.0 - currentGain) * 0.03
            return
        }
        let targetRMS: Float = 0.16
        let desired = min(maxUpGain, max(0.35, targetRMS / rms))
        let coeff: Float = desired < currentGain ? 0.30 : 0.04
        currentGain += (desired - currentGain) * coeff
        if !currentGain.isFinite { currentGain = 1.0 }
    }

    /// 平滑软膝限幅（0.85 起软饱和至 <1.0，杜绝高增益硬截断破音）与 NaN 防护
    static func sanitizeAndClip(_ ptr: UnsafeMutablePointer<Float>, count: Int, stride: vDSP_Stride) -> Bool {
        var foundNonFinite = false
        let step = Int(stride)
        let knee: Float = 0.85
        let headroom: Float = 0.15
        var idx = 0
        for _ in 0..<count {
            let v = ptr[idx]
            if !v.isFinite {
                ptr[idx] = 0
                foundNonFinite = true
            } else if v > knee {
                ptr[idx] = knee + headroom * tanhf((v - knee) / headroom)
            } else if v < -knee {
                ptr[idx] = -(knee + headroom * tanhf((-v - knee) / headroom))
            }
            idx += step
        }
        return foundNonFinite
    }

    /// 供白盒单元测试离线下验证 Pre-EQ FFT 智能修音在低采样率、静音与浑浊/齿音信号下的表现
    public static func analyzeSmartWindowForTesting(
        samples: [Float],
        sampleRate: Double,
        intensity: AudioSmartIntensity
    ) -> (offsets: [Float], telemetry: AudioSmartTelemetry) {
        let analyzer = AudioSmartAnalyzer { _, _, _ in }
        return analyzer.analyzeOfflineWindowForTesting(samples: samples, sampleRate: sampleRate, intensity: intensity)
    }
}
