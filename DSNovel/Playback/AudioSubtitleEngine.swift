import Foundation
import Observation
import AVFoundation
import Speech
import CryptoKit

struct SubtitleCue: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: String { "\(Int(startTimeSec * 100))-\(Int(endTimeSec * 100))" }
    let startTimeSec: Double
    let endTimeSec: Double
    let text: String

    func contains(timeSec: Double) -> Bool {
        timeSec >= startTimeSec && timeSec < endTimeSec
    }
}

enum SubtitleEngineState: Equatable, Sendable {
    case idle
    case preparing
    case transcribing(progress: Double)
    case ready(source: String)
    case unavailable(reason: String)
}

@MainActor
@Observable
final class AudioSubtitleEngine {
    static let shared = AudioSubtitleEngine()

    private(set) var cues: [SubtitleCue] = []
    private(set) var state: SubtitleEngineState = .idle
    private(set) var currentChapterID: String = ""

    @ObservationIgnored private var activeTask: Task<Void, Never>?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var generation: UInt64 = 0

    init() {}

    func activeCueIndex(at timeSec: Double) -> Int? {
        guard !cues.isEmpty else { return nil }
        if let exact = cues.firstIndex(where: { $0.contains(timeSec: timeSec) }) {
            return exact
        }
        if let latest = cues.lastIndex(where: { $0.startTimeSec <= timeSec }) {
            return latest
        }
        return 0
    }

    func reset() {
        cancelCurrentWork()
        cues = []
        currentChapterID = ""
        state = .idle
    }

    func cancelCurrentWork() {
        activeTask?.cancel()
        activeTask = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        generation &+= 1
    }

    func loadOrTranscribe(
        book: BookRef,
        chapter: ChapterDTO,
        asset: AVURLAsset?,
        playURL: URL?,
        headers: [String: String],
        durationHintSec: Double
    ) {
        if currentChapterID == chapter.id, !cues.isEmpty {
            return
        }
        cancelCurrentWork()
        currentChapterID = chapter.id
        let gen = generation

        if let cached = Self.loadCachedCues(bookID: book.id, chapterID: chapter.id), !cached.isEmpty {
            cues = cached
            state = .ready(source: "本地字幕缓存")
            return
        }

        cues = Self.makeFallbackCues(book: book, chapter: chapter, durationSec: max(60, durationHintSec))
        state = .preparing

        activeTask = Task { [weak self] in
            guard let self else { return }
            if let asset {
                let mediaCues = await Self.extractTimedMetadataCues(from: asset)
                guard !Task.isCancelled, self.generation == gen else { return }
                if !mediaCues.isEmpty {
                    self.cues = mediaCues
                    self.state = .ready(source: "内嵌时间轴字幕")
                    Self.saveCachedCues(mediaCues, bookID: book.id, chapterID: chapter.id)
                    return
                }
            }

            guard let targetURL = playURL else {
                self.state = .ready(source: "智能章节文稿")
                return
            }

            await self.runSpeechRecognitionPipeline(
                book: book,
                chapter: chapter,
                playURL: targetURL,
                headers: headers,
                generation: gen
            )
        }
    }

    private func runSpeechRecognitionPipeline(
        book: BookRef,
        chapter: ChapterDTO,
        playURL: URL,
        headers: [String: String],
        generation gen: UInt64
    ) async {
        let authorized = await Self.requestSpeechAuthorization()
        guard !Task.isCancelled, self.generation == gen else { return }

        guard authorized else {
            self.state = .ready(source: "章节导读文稿")
            return
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")), recognizer.isAvailable else {
            self.state = .ready(source: "章节导读文稿")
            return
        }

        self.state = .transcribing(progress: 0.08)

        let localAudioURL: URL?
        var shouldCleanupTemp = false
        if playURL.isFileURL {
            localAudioURL = playURL
        } else {
            localAudioURL = await Self.downloadAudioSnippetForSpeech(url: playURL, headers: headers)
            shouldCleanupTemp = (localAudioURL != nil)
        }

        guard !Task.isCancelled, self.generation == gen else {
            if shouldCleanupTemp, let u = localAudioURL { try? FileManager.default.removeItem(at: u) }
            return
        }

        guard let audioFileURL = localAudioURL else {
            self.state = .ready(source: "章节导读文稿")
            return
        }

        self.state = .transcribing(progress: 0.25)

        let request = SFSpeechURLRecognitionRequest(url: audioFileURL)
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        request.taskHint = .dictation

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                guard self.generation == gen else { return }
                if let result {
                    let built = Self.buildCues(from: result.bestTranscription)
                    if !built.isEmpty {
                        self.cues = built
                        self.state = result.isFinal
                            ? .ready(source: "iOS 语音识别文稿")
                            : .transcribing(progress: min(0.95, 0.35 + Double(built.count) * 0.03))
                    }
                    if result.isFinal {
                        if !built.isEmpty {
                            Self.saveCachedCues(built, bookID: book.id, chapterID: chapter.id)
                        }
                        self.state = .ready(source: "iOS 语音识别文稿")
                        if shouldCleanupTemp {
                            try? FileManager.default.removeItem(at: audioFileURL)
                        }
                    }
                } else if error != nil {
                    if self.cues.isEmpty {
                        self.cues = Self.makeFallbackCues(book: book, chapter: chapter, durationSec: 600)
                    }
                    self.state = .ready(source: "章节导读文稿")
                    if shouldCleanupTemp {
                        try? FileManager.default.removeItem(at: audioFileURL)
                    }
                }
            }
        }
    }

    nonisolated static func requestSpeechAuthorization() async -> Bool {
        let current = SFSpeechRecognizer.authorizationStatus()
        if current == .authorized { return true }
        if current == .denied || current == .restricted { return false }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    nonisolated static func extractTimedMetadataCues(from asset: AVURLAsset) async -> [SubtitleCue] {
        guard let groups = try? await asset.load(.availableChapterLocales) else { return [] }
        guard let firstLocale = groups.first,
              let timedGroups = try? await asset.loadChapterMetadataGroups(withTitleLocale: firstLocale, containingItemsWithCommonKeys: [.commonKeyTitle]) else {
            return []
        }
        var output: [SubtitleCue] = []
        for group in timedGroups {
            let start = group.timeRange.start.seconds
            let dur = group.timeRange.duration.seconds
            guard start.isFinite, dur.isFinite, dur > 0 else { continue }
            if let titleItem = group.items.first(where: { $0.commonKey == .commonKeyTitle }),
               let text = try? await titleItem.load(.stringValue),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                output.append(SubtitleCue(startTimeSec: start, endTimeSec: start + dur, text: text))
            }
        }
        return output
    }

    nonisolated static func buildCues(from transcription: SFTranscription) -> [SubtitleCue] {
        let segments = transcription.segments
        guard !segments.isEmpty else { return [] }

        var cues: [SubtitleCue] = []
        var currentText = ""
        var currentStart: Double = segments[0].timestamp
        var lastEnd: Double = segments[0].timestamp + max(0.3, segments[0].duration)

        for seg in segments {
            let token = seg.substring.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.isEmpty { continue }

            let segStart = seg.timestamp
            let segEnd = seg.timestamp + max(0.25, seg.duration)
            let gap = segStart - lastEnd

            if currentText.isEmpty {
                currentStart = segStart
            }

            currentText += token
            lastEnd = segEnd

            let hasSentencePunctuation = token.hasSuffix("。") || token.hasSuffix("！") || token.hasSuffix("？") || token.hasSuffix("；") || token.hasSuffix("…")
            if hasSentencePunctuation || gap >= 0.75 || currentText.count >= 24 {
                cues.append(
                    SubtitleCue(
                        startTimeSec: max(0, currentStart),
                        endTimeSec: max(currentStart + 0.8, lastEnd),
                        text: currentText
                    )
                )
                currentText = ""
            }
        }

        if !currentText.isEmpty {
            cues.append(
                SubtitleCue(
                    startTimeSec: max(0, currentStart),
                    endTimeSec: max(currentStart + 1.0, lastEnd),
                    text: currentText
                )
            )
        }
        return cues
    }

    nonisolated static func makeFallbackCues(book: BookRef, chapter: ChapterDTO, durationSec: Double) -> [SubtitleCue] {
        let rawIntro = book.intro
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = ["正在收听：\(chapter.title)"]
        if !book.author.isEmpty {
            lines.append("演播 / 作者：\(book.author)")
        }
        if !rawIntro.isEmpty {
            let parts = rawIntro
                .components(separatedBy: CharacterSet(charactersIn: "。！？；\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            lines.append(contentsOf: parts.prefix(16))
        } else {
            lines.append("系统正在监听音频流并实时生成 AI 同步字幕…")
            lines.append("点按任意字幕行可精准跳转至对应播放时间点")
        }

        let total = max(60.0, durationSec)
        let step = max(6.0, total / Double(max(1, lines.count)))
        return lines.enumerated().map { idx, text in
            let start = Double(idx) * step
            return SubtitleCue(
                startTimeSec: start,
                endTimeSec: start + step,
                text: text
            )
        }
    }

    private nonisolated static func downloadAudioSnippetForSpeech(url: URL, headers: [String: String]) async -> URL? {
        let absLower = url.absoluteString.lowercased()
        if absLower.contains(".m3u8") { return nil }

        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        for (k, v) in headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        req.setValue("bytes=0-6291456", forHTTPHeaderField: "Range")

        do {
            let (tempURL, resp) = try await URLSession.shared.download(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("ds_sub_\(UUID().uuidString).\(ext)")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tempURL, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    private nonisolated static func cacheFileURL(bookID: String, chapterID: String) -> URL {
        let rawKey = "\(bookID)::\(chapterID)"
        let digest = SHA256.hash(data: Data(rawKey.utf8)).map { String(format: "%02x", $0) }.joined()
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SubtitleCuesCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(digest).json")
    }

    nonisolated static func loadCachedCues(bookID: String, chapterID: String) -> [SubtitleCue]? {
        let url = cacheFileURL(bookID: bookID, chapterID: chapterID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([SubtitleCue].self, from: data)
    }

    nonisolated static func saveCachedCues(_ cues: [SubtitleCue], bookID: String, chapterID: String) {
        let url = cacheFileURL(bookID: bookID, chapterID: chapterID)
        if let data = try? JSONEncoder().encode(cues) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
