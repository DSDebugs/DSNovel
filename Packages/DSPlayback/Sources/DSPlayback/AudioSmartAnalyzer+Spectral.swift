import Accelerate
import Foundation

extension AudioSmartAnalyzer {
    func computeSpectralTargets(
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
