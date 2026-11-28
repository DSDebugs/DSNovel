import AVFoundation
import DSCore
import Foundation
import MediaToolbox

/// AudioTapProcessor 混音管线构建与实时参数更新（拆分保持单文件 ≤ 384 行）
extension AudioTapProcessor {
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
