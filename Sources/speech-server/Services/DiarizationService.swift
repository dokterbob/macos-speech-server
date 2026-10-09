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
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(makeBackend: @escaping @Sendable () -> any DiarizationBackend = { CommunityDiarizationBackend() }) {
        self.makeBackend = makeBackend
    }

    func diarize(audioURL: URL) async throws -> [SpeakerTurn] {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        }
        else {
            busy = true
        }
        defer {
            if waiters.isEmpty {
                busy = false
            }
            else {
                waiters.removeFirst().resume()
            }
        }
        try Task.checkCancellation()

        if backend == nil {
            let candidate = makeBackend()
            try await candidate.prepare()
            backend = candidate
        }
        try Task.checkCancellation()
        return try await backend!.process(audioURL)
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
func alignSpeakers(segments: [SegmentResult], turns: [SpeakerTurn]) -> [SpeakerAlignedSegment] {
    let sortedTurns = turns.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
        .sorted { $0.start == $1.start ? $0.speaker < $1.speaker : $0.start < $1.start }
    var latestEnd = -Double.infinity
    let prefixEnds = sortedTurns.map { turn in
        latestEnd = max(latestEnd, turn.end)
        return latestEnd
    }

    func speaker(start: Double, end: Double) -> String {
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
        guard !segment.words.isEmpty else {
            aligned.append(
                SpeakerAlignedSegment(
                    text: segment.text, start: segment.start, end: segment.end, confidence: segment.confidence,
                    speaker: speaker(start: segment.start, end: segment.end)))
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
            let label = speaker(start: word.start, end: word.end)
            if label != currentSpeaker {
                flush()
                words = []
                start = word.start
                currentSpeaker = label
            }
            words.append(word.word)
            end = word.end
        }
        flush()
    }
    return aligned
}
