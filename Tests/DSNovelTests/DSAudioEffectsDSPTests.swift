import DSPlayback
import Foundation
import Testing

@Suite("DSAudioEffects 可调响度、防爆音动态均衡与持久化测试")
struct DSAudioEffectsDSPTests {
    @Test("AudioDSPParameters 兼容旧开关并准确计算 needsProcessing")
    func dspParametersCompatibilityAndNeedsProcessing() {
        let flat = AudioDSPParameters()
        #expect(!flat.needsProcessing)
        #expect(flat.volumeBoostDB == 0)

        let legacy = AudioDSPParameters(volumeBoostEnabled: true)
        #expect(legacy.needsProcessing)
        #expect(legacy.volumeBoostDB >= 2.0)

        let customBoost = AudioDSPParameters(volumeBoostDB: 6.0)
        #expect(customBoost.needsProcessing)
        #expect(customBoost.volumeBoostEnabled)
        #expect(customBoost.volumeBoostDB == 6.0)

        let levelingOnly = AudioDSPParameters(dynamicLevelingEnabled: true)
        #expect(levelingOnly.needsProcessing)
    }

    @Test("AudioTapDSP 持久化恢复 EQ 预设、响度分贝与防爆音动态均衡")
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

        let dsp2 = AudioTapDSP()
        dsp2.bindPersistence(defaults)
        #expect(dsp2.preset == .voiceBoost)
        #expect(dsp2.volumeBoostDB == 6.0)
        #expect(dsp2.dynamicLevelingEnabled)
    }
}
