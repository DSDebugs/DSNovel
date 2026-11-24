import DSPlayback
import Foundation
import Testing

@Suite("DSAudioEffects 可调响度、AI 智能修音与持久化测试")
struct DSAudioEffectsDSPTests {
    @Test("AudioDSPParameters 兼容旧开关并准确计算 needsProcessing")
    func dspParametersCompatibilityAndNeedsProcessing() {
        let flat = AudioDSPParameters()
        #expect(!flat.needsProcessing)
        #expect(flat.volumeBoostDB == 0)
        #expect(!flat.smartRepairEnabled)

        let legacy = AudioDSPParameters(volumeBoostEnabled: true)
        #expect(legacy.needsProcessing)
        #expect(legacy.volumeBoostDB >= 2.0)

        let customBoost = AudioDSPParameters(volumeBoostDB: 6.0)
        #expect(customBoost.needsProcessing)
        #expect(customBoost.volumeBoostEnabled)
        #expect(customBoost.volumeBoostDB == 6.0)

        let levelingOnly = AudioDSPParameters(dynamicLevelingEnabled: true)
        #expect(levelingOnly.needsProcessing)

        let smartOnly = AudioDSPParameters(smartRepairEnabled: true, smartRepairIntensity: .strong)
        #expect(smartOnly.needsProcessing)
        #expect(smartOnly.smartRepairIntensity == .strong)
    }

    @Test("AI 智能修音与静态风格预设合并并执行 [-10, +10] dB 联合安全限幅")
    func smartRepairCombinedBandGainsClamping() {
        let staticVoice = AudioEQPreset.voiceBoost.bandGainsDB
        let extremeOffsets: [Float] = [-7.0, -3.0, 6.0, 6.5, -2.5]

        let bypassed = AudioDSPParameters.combinedBandGains(
            staticBands: staticVoice,
            smartOffsets: extremeOffsets,
            smartEnabled: false
        )
        #expect(bypassed == staticVoice)

        let combined = AudioDSPParameters.combinedBandGains(
            staticBands: staticVoice,
            smartOffsets: extremeOffsets,
            smartEnabled: true
        )
        #expect(combined == [-10.0, -4.0, 10.0, 10.0, -1.5])
    }

    @Test("白盒测试：Pre-EQ FFT 在 8kHz 低采样率、静音与浑浊/齿音合成信号下安全无越界")
    func smartAnalyzerWhiteBoxSpectralBehavior() {
        let count = 1024

        // 1. 静音窗口：不误触发分析、偏移全零
        let silence = Array(repeating: Float(0.0005), count: count)
        let silenceRes = AudioTapProcessor.analyzeSmartWindowForTesting(
            samples: silence,
            sampleRate: 44_100,
            intensity: .standard
        )
        #expect(!silenceRes.telemetry.isAnalyzing)
        #expect(silenceRes.offsets == [0, 0, 0, 0, 0])

        // 2. 8kHz 老旧低码率书源：不崩溃、不越界、8kHz 齿音段安全归零
        let lowRateTone: [Float] = (0..<count).map { i in
            sinf(2.0 * Float.pi * 150.0 * Float(i) / 8_000.0) * 0.4
        }
        let lowRateRes = AudioTapProcessor.analyzeSmartWindowForTesting(
            samples: lowRateTone,
            sampleRate: 8_000,
            intensity: .strong
        )
        #expect(lowRateRes.offsets.count == 5)
        #expect(lowRateRes.offsets.allSatisfy { $0.isFinite && abs($0) <= AudioSmartIntensity.strong.maxCorrectionDB + 0.001 })
        #expect(lowRateRes.offsets[4] == 0)

        // 3. 44.1kHz 低频严重发闷信号（120Hz 远强于 1.2kHz）：100Hz 频段应产生负向去闷衰减
        let muddySignal: [Float] = (0..<count).map { i in
            let t = Float(i) / 44_100.0
            return sinf(2.0 * Float.pi * 120.0 * t) * 0.6 + sinf(2.0 * Float.pi * 1200.0 * t) * 0.08
        }
        let muddyRes = AudioTapProcessor.analyzeSmartWindowForTesting(
            samples: muddySignal,
            sampleRate: 44_100,
            intensity: .standard
        )
        #expect(muddyRes.telemetry.isAnalyzing)
        #expect(muddyRes.offsets[0] < 0)

        // 4. 44.1kHz 高频刺耳齿音信号（7.5kHz 远强于 1.2kHz）：8kHz 频段应产生负向抑齿音衰减
        let sibilantSignal: [Float] = (0..<count).map { i in
            let t = Float(i) / 44_100.0
            return sinf(2.0 * Float.pi * 7500.0 * t) * 0.55 + sinf(2.0 * Float.pi * 1200.0 * t) * 0.08
        }
        let sibRes = AudioTapProcessor.analyzeSmartWindowForTesting(
            samples: sibilantSignal,
            sampleRate: 44_100,
            intensity: .standard
        )
        #expect(sibRes.telemetry.isAnalyzing)
        #expect(sibRes.offsets[4] < 0)
    }

    @Test("AudioTapDSP 持久化恢复 EQ 预设、AI 智能修音、响度分贝与防爆音动态均衡")
    @MainActor
    func dspPersistenceRoundTrip() {
        let suite = "dsnovel.test.dsp.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { defaults.removePersistentDomain(forName: suite) }

        let dsp1 = AudioTapDSP()
        dsp1.bindPersistence(defaults)
        dsp1.preset = .voiceBoost
        dsp1.volumeBoostDB = 6.0
        dsp1.dynamicLevelingEnabled = true
        dsp1.smartRepairEnabled = true
        dsp1.smartRepairIntensity = .strong

        let dsp2 = AudioTapDSP()
        dsp2.bindPersistence(defaults)
        #expect(dsp2.preset == .voiceBoost)
        #expect(dsp2.volumeBoostDB == 6.0)
        #expect(dsp2.dynamicLevelingEnabled)
        #expect(dsp2.smartRepairEnabled)
        #expect(dsp2.smartRepairIntensity == .strong)
    }
}
