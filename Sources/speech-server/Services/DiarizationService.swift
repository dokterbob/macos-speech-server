import FluidAudio
import Foundation
import Vapor

struct SpeakerTurn: Sendable {
    let speaker: String
    let start: Double
    let end: Double
}

protocol DiarizationService: Sendable {
    func diarize(audioURL: URL) async throws -> [SpeakerTurn]
}

protocol DiarizationBackend: Sendable {
    func prepare() async throws
    func process(_ url: URL) async throws -> [SpeakerTurn]
}

/// The explicit gate remains held across awaits: actor isolation alone would allow
/// multiple requests to load models or run inference concurrently through reentrancy.
actor FluidDiarizationService: DiarizationService {
    private let makeBackend: @Sendable () -> any DiarizationBackend
    private var backend: (any DiarizationBackend)?
    private var busy = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    init(makeBackend: @escaping @Sendable () -> any DiarizationBackend = { CommunityDiarizationBackend() }) {
        self.makeBackend = makeBackend
    }

    func diarize(audioURL: URL) async throws -> [SpeakerTurn] {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()

        if backend == nil {
            let candidate = makeBackend()
            try await candidate.prepare()
            backend = candidate
        }
        try Task.checkCancellation()
        return try await backend!.process(audioURL)
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        guard busy else {
            busy = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Cancellation may happen before its handler can reach this actor.
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        // A queued request does not own the gate, so cancellation must not release it.
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        }
        else {
            // Transfer ownership while keeping the gate closed to new arrivals.
            waiters.removeFirst().continuation.resume()
        }
    }
}

/// Only accessed under FluidDiarizationService's gate. FluidAudio's manager is
/// not Sendable; this wrapper keeps model mutation and inference serialized.
private final class CommunityDiarizationBackend: DiarizationBackend, @unchecked Sendable {
    private let manager: OfflineDiarizerManager

    init() {
        var config = OfflineDiarizerConfig.default
        config.embedding.batchSize = 1
        manager = OfflineDiarizerManager(config: config)
    }

    func prepare() async throws {
        // FluidAudio 0.13.5 selects .all for segmentation/embedding/PLDA (ANE
        // where supported) and .cpuOnly for fbank. Its configuration argument
        // does not override this, so use the supported default loader.
        try await manager.prepareModels()
    }

    func process(_ url: URL) async throws -> [SpeakerTurn] {
        do {
            // Converts to disk-backed 16 kHz samples and cleans them up internally.
            let result = try await manager.process(url)
            return result.segments.map {
                SpeakerTurn(
                    speaker: $0.speakerId,
                    start: Double($0.startTimeSeconds),
                    end: Double($0.endTimeSeconds))
            }
        }
        catch OfflineDiarizationError.noSpeechDetected {
            return []
        }
    }
}

struct DiarizationServiceKey: StorageKey {
    typealias Value = any DiarizationService
}

extension Application {
    var diarizationService: any DiarizationService {
        get { storage[DiarizationServiceKey.self]! }
        set { storage[DiarizationServiceKey.self] = newValue }
    }
}

struct SpeakerAlignedSegment {
    let text: String
    let start: Double
    let end: Double
    let confidence: Float
    let speaker: String
}

/// Assign each word by maximum overlap, then group adjacent words of the same
/// speaker within an ASR segment. Without word timing, retain the whole segment.
/// No overlap means unknown; never invent word times or duplicate text for overlap.
func alignSpeakers(segments: [SegmentResult], turns: [SpeakerTurn], duration: Double) -> [SpeakerAlignedSegment] {
    let sortedTurns = turns.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
        .sorted { $0.start == $1.start ? $0.speaker < $1.speaker : $0.start < $1.start }
    var latestEnd = -Double.infinity
    let prefixEnds = sortedTurns.map { turn in
        latestEnd = max(latestEnd, turn.end)
        return latestEnd
    }

    func speaker(start: Double, end: Double) -> String {
        guard end > start else { return "unknown" }
        // Skip past turns by binary search rather than scanning the recording
        // for every word. Prefix maxima also handle overlapping speaker turns.
        var lower = 0
        var upper = prefixEnds.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if prefixEnds[middle] <= start {
                lower = middle + 1
            }
            else {
                upper = middle
            }
        }
        var overlaps: [String: Double] = [:]
        var order: [String] = []
        for turn in sortedTurns[lower...] {
            if turn.start >= end { break }
            let overlap = min(end, turn.end) - max(start, turn.start)
            guard overlap > 0 else { continue }
            if overlaps[turn.speaker] == nil { order.append(turn.speaker) }
            overlaps[turn.speaker, default: 0] += overlap
        }
        var best = "unknown"
        var bestOverlap = 0.0
        for candidate in order {
            if let overlap = overlaps[candidate], overlap > bestOverlap {
                best = candidate
                bestOverlap = overlap
            }
        }
        return best
    }

    var aligned: [SpeakerAlignedSegment] = []
    for segment in segments {
        let segmentStart = min(max(0, segment.start), max(0, duration))
        let segmentEnd = min(max(segmentStart, segment.end), max(0, duration))
        guard !segment.words.isEmpty else {
            aligned.append(
                SpeakerAlignedSegment(
                    text: segment.text, start: segmentStart, end: segmentEnd, confidence: segment.confidence,
                    speaker: speaker(start: segmentStart, end: segmentEnd)))
            continue
        }
        var currentSpeaker: String?
        var words: [String] = []
        var start = 0.0
        var end = 0.0
        func flush() {
            guard let currentSpeaker else { return }
            aligned.append(
                SpeakerAlignedSegment(
                    text: words.joined(separator: " "), start: start, end: end,
                    confidence: segment.confidence, speaker: currentSpeaker))
        }
        for word in segment.words {
            // ASR runs on padded audio. Clamp before matching so padding cannot
            // contribute overlap or extend response timestamps past real audio.
            let wordStart = min(segmentEnd, max(segmentStart, word.start))
            let wordEnd = min(segmentEnd, max(wordStart, word.end))
            let label = speaker(start: wordStart, end: wordEnd)
            if label != currentSpeaker {
                flush()
                words = []
                start = wordStart
                end = wordEnd
                currentSpeaker = label
            }
            words.append(word.word)
            start = min(start, wordStart)
            end = max(end, wordEnd)
        }
        flush()
    }
    return aligned
}
