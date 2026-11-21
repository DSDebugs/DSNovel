import Accelerate
import AVFoundation
import Foundation

/// AudioTapProcessor 底层 biquad 系数计算、实时 PCM 渲染与白盒离线单测扩展（拆分保持单文件 <= 385 行）
extension AudioTapProcessor {
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
                let alpha = sin(w0) / 2.4
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
        delayRight: inout [Float]
    ) -> Bool {
        let baseGain = params.fadeGain * (params.volumeBoostEnabled ? 1.25 : 1.0)
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
                if let s = setup {
                    if chIdx == 0 {
                        vDSP_biquad(s, &delayLeft, samples, 1, samples, 1, vDSP_Length(frames))
                    } else if chIdx == 1 {
                        vDSP_biquad(s, &delayRight, samples, 1, samples, 1, vDSP_Length(frames))
                    }
                }
                var gain = isMono ? baseGain : ((chIdx == 0) ? leftGain : rightGain)
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
                    delayRight: &delayRight
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

        samples.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            _ = Self.processInterleavedPCM(
                samples: base, frames: frames, channels: channels,
                params: params, setup: holder.setup,
                delayLeft: &delayLeft, delayRight: &delayRight
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
        delayRight: inout [Float]
    ) -> Bool {
        let baseGain = params.fadeGain * (params.volumeBoostEnabled ? 1.25 : 1.0)
        let isMono = channels == 1
        let leftGain = isMono ? baseGain : baseGain * (params.stereoBalance > 0 ? (1.0 - params.stereoBalance) : 1.0)
        let rightGain = baseGain * (params.stereoBalance < 0 ? (1.0 + params.stereoBalance) : 1.0)
        let stride = vDSP_Stride(channels)

        if let s = setup {
            vDSP_biquad(s, &delayLeft, samples, stride, samples, stride, vDSP_Length(frames))
            if channels >= 2 {
                let rightPtr = samples.advanced(by: 1)
                vDSP_biquad(s, &delayRight, rightPtr, stride, rightPtr, stride, vDSP_Length(frames))
            }
        }
        var lGain = leftGain
        if abs(lGain - 1.0) > 0.001 {
            vDSP_vsmul(samples, stride, &lGain, samples, stride, vDSP_Length(frames))
        }
        if channels >= 2 {
            var rGain = rightGain
            if abs(rGain - 1.0) > 0.001 {
                let rightPtr = samples.advanced(by: 1)
                vDSP_vsmul(rightPtr, stride, &rGain, rightPtr, stride, vDSP_Length(frames))
            }
        }
        return sanitizeAndClip(samples, count: frames * channels, stride: 1)
    }

    static func sanitizeAndClip(_ ptr: UnsafeMutablePointer<Float>, count: Int, stride: vDSP_Stride) -> Bool {
        var foundNonFinite = false
        let step = Int(stride)
        var idx = 0
        for _ in 0..<count {
            if !ptr[idx].isFinite {
                ptr[idx] = 0
                foundNonFinite = true
            }
            idx += step
        }
        var low: Float = -1.0
        var high: Float = 1.0
        vDSP_vclip(ptr, stride, &low, &high, ptr, stride, vDSP_Length(count))
        return foundNonFinite
    }
}
