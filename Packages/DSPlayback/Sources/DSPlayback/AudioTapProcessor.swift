import Accelerate
import AVFoundation
import CoreMedia
import Foundation
import MediaToolbox
import os

/// 实时 5 段 EQ + 声道平衡 + 响度增强 DSP 参数快照（跨音频渲染线程只读传递）
public struct AudioDSPParameters: Sendable, Equatable {
    public let bandGainsDB: [Float] // 60, 230, 910, 3600, 14000 Hz
    public let stereoBalance: Float // -1.0 ... 1.0
    public let volumeBoostEnabled: Bool
    public let fadeGain: Float      // 0.0 ... 1.0

    public init(
        bandGainsDB: [Float] = [0, 0, 0, 0, 0],
        stereoBalance: Float = 0,
        volumeBoostEnabled: Bool = false,
        fadeGain: Float = 1.0
    ) {
        self.bandGainsDB = bandGainsDB.count == 5 ? bandGainsDB : [0, 0, 0, 0, 0]
        self.stereoBalance = max(-1, min(1, stereoBalance))
        self.volumeBoostEnabled = volumeBoostEnabled
        self.fadeGain = max(0, min(1, fadeGain))
    }

    public static let centerFrequencies: [Double] = [60, 230, 910, 3600, 14000]
}

/// 底层 MTAudioProcessingTap + vDSP_biquad 实时处理器（AUD-50：双缓冲只读快照 + 极短 os_unfair_lock 指针交换 + 零分配首帧信号）
public final class AudioTapProcessor: @unchecked Sendable {
    static let maxRetiredSnapshots = 2

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

    final class TapContext: @unchecked Sendable {
        private let snapshotLock: OSAllocatedUnfairLock<RenderSnapshot>
        private let formatLock = OSAllocatedUnfairLock(initialState: FormatState())
        private let receiptLock = OSAllocatedUnfairLock(initialState: false)
        private let writerLock = NSLock()
        private var paramVersion: UInt64 = 0
        private var sampleRate: Double = 44_100
        private var retiredSnapshots: [RenderSnapshot] = []
        private let receiptSource: DispatchSourceUserDataOr

        /// 仅在音频渲染线程（prepare / process / unprepare 串行）访问，零锁竞争
        var delayLeft: [Float] = Array(repeating: 0, count: 14)
        var delayRight: [Float] = Array(repeating: 0, count: 14)

        init(params: AudioDSPParameters, onFirstReceipt: @escaping @Sendable () -> Void) {
            let initial = RenderSnapshot(params: params, biquad: BiquadHolder(gainsDB: params.bandGainsDB, sampleRate: 44_100))
            self.snapshotLock = OSAllocatedUnfairLock(initialState: initial)

            let source = DispatchSource.makeUserDataOrSource(queue: DispatchQueue.global(qos: .utility))
            source.setEventHandler {
                onFirstReceipt()
            }
            source.resume()
            self.receiptSource = source
        }

        deinit {
            receiptSource.cancel()
        }

        func currentSnapshot() -> RenderSnapshot {
            snapshotLock.withLock { $0 }
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
        }

        func markDelayResetPending() {
            formatLock.withLock { $0.needsDelayReset = true }
        }

        /// 实时音频线程零堆分配首帧回执：极短原子标志 + DispatchSourceUserDataOr 唤醒
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

        /// 在主/后台线程预构建新的只读快照并经极短 unfair lock 原子交换指针，旧快照由写线程延迟回收
        func updateParamsOffAudioThread(_ next: AudioDSPParameters) {
            writerLock.withLock {
                let current = snapshotLock.withLock { $0 }
                let needsNewFilter = current.params.bandGainsDB != next.bandGainsDB || current.biquad.sampleRate != sampleRate
                let holder = needsNewFilter ? BiquadHolder(gainsDB: next.bandGainsDB, sampleRate: sampleRate) : current.biquad
                let nextSnapshot = RenderSnapshot(params: next, biquad: holder)
                paramVersion &+= 1
                let previous = snapshotLock.withLock { active -> RenderSnapshot in
                    let old = active
                    active = nextSnapshot
                    return old
                }
                retireSnapshotLocked(previous)
            }
        }

        func scheduleSampleRateRebuild(_ newRate: Double) {
            let work: ([Float], UInt64)? = writerLock.withLock {
                sampleRate = newRate
                let current = snapshotLock.withLock { $0 }
                if current.biquad.sampleRate == newRate {
                    return nil
                }
                return (current.params.bandGainsDB, paramVersion)
            }
            guard let (gains, capturedVersion) = work else { return }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let rebuilt = BiquadHolder(gainsDB: gains, sampleRate: newRate)
                self.writerLock.withLock {
                    guard self.paramVersion == capturedVersion, self.sampleRate == newRate else { return }
                    let currentParams = self.snapshotLock.withLock { $0.params }
                    let nextSnapshot = RenderSnapshot(params: currentParams, biquad: rebuilt)
                    let previous = self.snapshotLock.withLock { active -> RenderSnapshot in
                        let old = active
                        active = nextSnapshot
                        return old
                    }
                    self.retireSnapshotLocked(previous)
                }
            }
        }

        private func retireSnapshotLocked(_ snapshot: RenderSnapshot) {
            retiredSnapshots.append(snapshot)
            if retiredSnapshots.count > AudioTapProcessor.maxRetiredSnapshots {
                retiredSnapshots.removeFirst(retiredSnapshots.count - AudioTapProcessor.maxRetiredSnapshots)
            }
        }
    }

    let contextLock = NSLock()
    var activeContext: TapContext?
    var activeGeneration: UInt64 = 0
    var latestParams = AudioDSPParameters()
    var paramsVersion: UInt64 = 0

    public init() {}

    public func updateParameters(_ params: AudioDSPParameters) {
        let ctx = contextLock.withLock { () -> TapContext? in
            latestParams = params
            paramsVersion &+= 1
            return activeContext
        }
        ctx?.updateParamsOffAudioThread(params)
    }

    @MainActor
    public func buildAudioMix(
        for asset: AVAsset,
        initialParams: AudioDSPParameters,
        generation: UInt64 = 0,
        onFirstReceipt: @escaping @Sendable () -> Void
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

        let ctx = TapContext(params: resolvedInitParams, onFirstReceipt: onFirstReceipt)

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passUnretained(ctx).toOpaque(),
            init: { _, clientInfo, tapStorageOut in
                guard let clientInfo else { return }
                tapStorageOut.pointee = Unmanaged<TapContext>.fromOpaque(clientInfo).retain().toOpaque()
            },
            finalize: { tap in
                Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, processingFormat in
                let ctx = Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                ctx.configureFormatAndRebuild(processingFormat.pointee)
            },
            unprepare: { tap in
                let ctx = Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                ctx.markDelayResetPending()
            },
            process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
                var timeRange = CMTimeRange.zero
                let status = MTAudioProcessingTapGetSourceAudio(
                    tap, numberFrames, bufferListInOut, flagsOut, &timeRange, numberFramesOut
                )
                guard status == noErr else { return }

                let ctx = Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let frames = Int(numberFramesOut.pointee)
                guard frames > 0 else { return }

                let format = ctx.readFormatAndConsumeDelayReset()
                guard format.isFloat32 else { return }
                if format.needsDelayReset {
                    ctx.zeroDelayLinesOnAudioThread()
                }
                ctx.signalFirstReceiptIfNeeded()

                let snapshot = ctx.currentSnapshot()
                let detectedNonFinite = AudioTapProcessor.processAudioBufferList(
                    bufferListInOut,
                    frames: frames,
                    format: format,
                    params: snapshot.params,
                    setup: snapshot.biquad.setup,
                    delayLeft: &ctx.delayLeft,
                    delayRight: &ctx.delayRight
                )

                if detectedNonFinite
                    || ctx.delayLeft.contains(where: { !$0.isFinite })
                    || ctx.delayRight.contains(where: { !$0.isFinite }) {
                    ctx.zeroDelayLinesOnAudioThread()
                }
            }
        )

        var tapRef: MTAudioProcessingTap?
        let err = withExtendedLifetime(ctx) {
            MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tapRef)
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
