import Accelerate
import AVFoundation
import CoreMedia
import Foundation
import MediaToolbox
import os

private let dsAudioTapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, tapStorageOut in
    guard let clientInfo else { return }
    tapStorageOut.pointee = Unmanaged<AudioTapProcessor.TapContext>.fromOpaque(clientInfo).retain().toOpaque()
}

private let dsAudioTapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    let storage = MTAudioProcessingTapGetStorage(tap)
    Unmanaged<AudioTapProcessor.TapContext>.fromOpaque(storage).release()
}

private let dsAudioTapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, processingFormat in
    let storage = MTAudioProcessingTapGetStorage(tap)
    let ctx = Unmanaged<AudioTapProcessor.TapContext>.fromOpaque(storage).takeUnretainedValue()
    ctx.configureFormatAndRebuild(processingFormat.pointee)
}

private let dsAudioTapUnprepare: MTAudioProcessingTapUnprepareCallback = { tap in
    let storage = MTAudioProcessingTapGetStorage(tap)
    let ctx = Unmanaged<AudioTapProcessor.TapContext>.fromOpaque(storage).takeUnretainedValue()
    ctx.markDelayResetPending()
}

private let dsAudioTapProcess: MTAudioProcessingTapProcessCallback = { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
    var timeRange = CMTimeRange.zero
    let status = MTAudioProcessingTapGetSourceAudio(
        tap,
        numberFrames,
        bufferListInOut,
        flagsOut,
        &timeRange,
        numberFramesOut
    )
    guard status == noErr else { return }

    let storage = MTAudioProcessingTapGetStorage(tap)
    let ctx = Unmanaged<AudioTapProcessor.TapContext>.fromOpaque(storage).takeUnretainedValue()
    let frames = Int(numberFramesOut.pointee)
    guard frames > 0 else { return }

    let format = ctx.readFormatAndConsumeDelayReset()
    guard format.isFloat32 else { return }
    if format.needsDelayReset {
        ctx.zeroDelayLinesOnAudioThread()
    }
    ctx.signalFirstReceiptIfNeeded()

    let snapshot = ctx.currentSnapshot()
    guard snapshot.params.needsProcessing else { return }

    // Pre-EQ 采样：在任何风格 EQ 处理前采集原始干声送入后台 vDSP_fft 分析
    if snapshot.params.smartRepairEnabled {
        ctx.capturePreEQSamples(
            bufferListInOut,
            frames: frames,
            format: format,
            sampleRate: snapshot.biquad.sampleRate,
            intensity: snapshot.params.smartRepairIntensity
        )
    }

    let detectedNonFinite = AudioTapProcessor.processAudioBufferList(
        bufferListInOut,
        frames: frames,
        format: format,
        params: snapshot.params,
        setup: snapshot.biquad.setup,
        delayLeft: &ctx.delayLeft,
        delayRight: &ctx.delayRight,
        levelingGain: &ctx.levelingGain
    )

    if detectedNonFinite
        || ctx.delayLeft.contains(where: { !$0.isFinite })
        || ctx.delayRight.contains(where: { !$0.isFinite }) {
        ctx.zeroDelayLinesOnAudioThread()
    }
}

/// 底层 MTAudioProcessingTap + vDSP_biquad + Pre-EQ 智能修音实时处理器
public final class AudioTapProcessor: @unchecked Sendable {
    static let maxRetiredSnapshots = 8

    final class TapContext: @unchecked Sendable {
        private let snapshotLock: OSAllocatedUnfairLock<RenderSnapshot>
        private let formatLock = OSAllocatedUnfairLock(initialState: FormatState())
        private let receiptLock = OSAllocatedUnfairLock(initialState: false)
        private let writerLock = NSLock()
        private var sampleRate: Double = 44_100
        private var smartOffsetsDB: [Float] = [0, 0, 0, 0, 0]
        private var retiredSnapshots: [RenderSnapshot] = []
        private let receiptSource: DispatchSourceUserDataOr
        private var smartAnalyzer: AudioSmartAnalyzer?
        private let onSmartTelemetry: (@Sendable (AudioSmartTelemetry) -> Void)?

        /// 仅在音频渲染线程（prepare / process / unprepare 串行）访问，零锁竞争
        var delayLeft: [Float] = Array(repeating: 0, count: 14)
        var delayRight: [Float] = Array(repeating: 0, count: 14)
        var levelingGain: Float = 1.0

        init(
            params: AudioDSPParameters,
            onFirstReceipt: @escaping @Sendable () -> Void,
            onSmartTelemetry: (@Sendable (AudioSmartTelemetry) -> Void)? = nil
        ) {
            let initial = RenderSnapshot(params: params, biquad: BiquadHolder(gainsDB: params.bandGainsDB, sampleRate: 44_100))
            self.snapshotLock = OSAllocatedUnfairLock(initialState: initial)
            self.onSmartTelemetry = onSmartTelemetry

            let source = DispatchSource.makeUserDataOrSource(queue: DispatchQueue.global(qos: .utility))
            source.setEventHandler {
                onFirstReceipt()
            }
            source.resume()
            self.receiptSource = source

            self.smartAnalyzer = AudioSmartAnalyzer { [weak self] offsets, telemetry, shouldEmitTelemetry in
                self?.applySmartOffsetsOffAudioThread(offsets, telemetry: telemetry, shouldEmitTelemetry: shouldEmitTelemetry)
            }
        }

        deinit {
            receiptSource.cancel()
        }

        func currentSnapshot() -> RenderSnapshot {
            snapshotLock.withLock { $0 }
        }

        func capturePreEQSamples(
            _ bufferList: UnsafeMutablePointer<AudioBufferList>,
            frames: Int,
            format: FormatState,
            sampleRate: Double,
            intensity: AudioSmartIntensity
        ) {
            smartAnalyzer?.capturePreEQSamples(
                bufferList,
                frames: frames,
                isNonInterleaved: format.isNonInterleaved,
                channels: format.channelsPerFrame,
                sampleRate: sampleRate,
                intensity: intensity
            )
        }

        func readFormatAndConsumeDelayReset() -> FormatState {
            formatLock.withLock { state in
                let copy = state
                state.needsDelayReset = false
                return copy
            }
        }

        func zeroDelayLinesOnAudioThread() {
            for i in delayLeft.indices { delayLeft[i] = 0 }
            for i in delayRight.indices { delayRight[i] = 0 }
            levelingGain = 1.0
        }

        func markDelayResetPending() {
            formatLock.withLock { $0.needsDelayReset = true }
            smartAnalyzer?.markResetPendingOnAudioThread()
        }

        func resetSmartAnalyzerOffAudioThread() {
            formatLock.withLock { $0.needsDelayReset = true }
            smartAnalyzer?.reset()
        }

        func signalFirstReceiptIfNeeded() {
            let isFirst = receiptLock.withLock { received -> Bool in
                if received { return false }
                received = true
                return true
            }
            if isFirst {
                receiptSource.or(data: 1)
            }
        }

        func configureFormatAndRebuild(_ format: AudioStreamBasicDescription) {
            let float32 = format.mFormatID == kAudioFormatLinearPCM
                && (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
                && format.mBitsPerChannel == 32
            let nonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
            let channels = max(1, Int(format.mChannelsPerFrame))
            let newRate = format.mSampleRate > 0 ? format.mSampleRate : 44_100
            formatLock.withLock { state in
                state.isFloat32 = float32
                state.isNonInterleaved = nonInterleaved
                state.channelsPerFrame = channels
                state.needsDelayReset = true
            }
            scheduleSampleRateRebuild(newRate)
        }

        func updateParamsOffAudioThread(_ next: AudioDSPParameters) {
            let didDisableSmart: Bool = writerLock.withLock {
                let current = snapshotLock.withLock { $0 }
                let wasSmart = current.params.smartRepairEnabled
                if !next.smartRepairEnabled {
                    smartOffsetsDB = [0, 0, 0, 0, 0]
                }
                let effectiveGains = AudioDSPParameters.combinedBandGains(
                    staticBands: next.bandGainsDB,
                    smartOffsets: smartOffsetsDB,
                    smartEnabled: next.smartRepairEnabled
                )
                let needsNewFilter = current.biquad.gainsDB != effectiveGains || current.biquad.sampleRate != sampleRate
                let holder = needsNewFilter ? BiquadHolder(gainsDB: effectiveGains, sampleRate: sampleRate) : current.biquad
                swapSnapshotLocked(RenderSnapshot(params: next, biquad: holder))
                return wasSmart && !next.smartRepairEnabled
            }
            if didDisableSmart {
                smartAnalyzer?.reset()
            }
        }

        private func applySmartOffsetsOffAudioThread(
            _ offsets: [Float],
            telemetry: AudioSmartTelemetry,
            shouldEmitTelemetry: Bool
        ) {
            let active: Bool = writerLock.withLock {
                let current = snapshotLock.withLock { $0 }
                guard current.params.smartRepairEnabled else { return false }
                smartOffsetsDB = offsets
                let effectiveGains = AudioDSPParameters.combinedBandGains(
                    staticBands: current.params.bandGainsDB,
                    smartOffsets: offsets,
                    smartEnabled: true
                )
                let maxDelta = zip(current.biquad.gainsDB, effectiveGains).reduce(Float(0)) { acc, pair in
                    max(acc, abs(pair.0 - pair.1))
                }
                if maxDelta >= 0.15 {
                    let holder = BiquadHolder(gainsDB: effectiveGains, sampleRate: sampleRate)
                    swapSnapshotLocked(RenderSnapshot(params: current.params, biquad: holder))
                }
                return true
            }
            if active && shouldEmitTelemetry {
                onSmartTelemetry?(telemetry)
            }
        }

        func scheduleSampleRateRebuild(_ newRate: Double) {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                self.writerLock.withLock {
                    self.sampleRate = newRate
                    let current = self.snapshotLock.withLock { $0 }
                    if current.biquad.sampleRate == newRate { return }
                    let effectiveGains = AudioDSPParameters.combinedBandGains(
                        staticBands: current.params.bandGainsDB,
                        smartOffsets: self.smartOffsetsDB,
                        smartEnabled: current.params.smartRepairEnabled
                    )
                    let rebuilt = BiquadHolder(gainsDB: effectiveGains, sampleRate: newRate)
                    self.swapSnapshotLocked(RenderSnapshot(params: current.params, biquad: rebuilt))
                }
            }
        }

        private func swapSnapshotLocked(_ nextSnapshot: RenderSnapshot) {
            let previous = snapshotLock.withLock { active -> RenderSnapshot in
                let old = active
                active = nextSnapshot
                return old
            }
            retiredSnapshots.append(previous)
            if retiredSnapshots.count > AudioTapProcessor.maxRetiredSnapshots {
                let overflow = Array(retiredSnapshots.prefix(retiredSnapshots.count - AudioTapProcessor.maxRetiredSnapshots))
                retiredSnapshots.removeFirst(overflow.count)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.15) {
                    _ = overflow.count
                }
            }
        }
    }

    let contextLock = NSLock()
    var activeContext: TapContext?
    var activeGeneration: UInt64 = 0
    var latestParams = AudioDSPParameters()
    var paramsVersion: UInt64 = 0

    public init() {}

    public func clearActiveContext() {
        let oldCtx: TapContext? = contextLock.withLock {
            let prev = activeContext
            activeContext = nil
            activeGeneration &+= 1
            return prev
        }
        oldCtx?.resetSmartAnalyzerOffAudioThread()
    }

    public func updateParameters(_ params: AudioDSPParameters) {
        let ctx = contextLock.withLock { () -> TapContext? in
            latestParams = params
            paramsVersion &+= 1
            return activeContext
        }
        ctx?.updateParamsOffAudioThread(params)
    }

    @MainActor public func buildAudioMix(
        for asset: AVAsset,
        initialParams: AudioDSPParameters,
        generation: UInt64 = 0,
        onFirstReceipt: @escaping @Sendable () -> Void,
        onSmartTelemetry: (@Sendable (AudioSmartTelemetry) -> Void)? = nil
    ) async -> AVMutableAudioMix? {
        let entryParamsVersion = contextLock.withLock { paramsVersion }
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio),
              let audioTrack = tracks.first,
              !Task.isCancelled else {
            return nil
        }

        let resolvedInitParams: AudioDSPParameters? = contextLock.withLock {
            guard generation >= activeGeneration else { return nil }
            return paramsVersion != entryParamsVersion ? latestParams : initialParams
        }
        guard let resolvedInitParams else { return nil }

        let ctx = TapContext(
            params: resolvedInitParams,
            onFirstReceipt: onFirstReceipt,
            onSmartTelemetry: onSmartTelemetry
        )

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passUnretained(ctx).toOpaque(),
            init: dsAudioTapInit,
            finalize: dsAudioTapFinalize,
            prepare: dsAudioTapPrepare,
            unprepare: dsAudioTapUnprepare,
            process: dsAudioTapProcess
        )

        var tapRef: MTAudioProcessingTap?
        let err = withExtendedLifetime(ctx) {
            MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tapRef)
        }
        guard err == noErr, let tap = tapRef else { return nil }

        let (accepted, newerParams) = contextLock.withLock { () -> (Bool, AudioDSPParameters?) in
            guard !Task.isCancelled, generation >= activeGeneration else { return (false, nil) }
            activeGeneration = generation
            activeContext = ctx
            if paramsVersion != entryParamsVersion {
                return (true, latestParams)
            }
            latestParams = initialParams
            return (true, nil)
        }
        guard accepted else { return nil }
        if let newerParams, newerParams != resolvedInitParams {
            ctx.updateParamsOffAudioThread(newerParams)
        }

        let inputParams = AVMutableAudioMixInputParameters(track: audioTrack)
        inputParams.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [inputParams]
        return mix
    }
}
