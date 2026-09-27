import FluidAudio
import Foundation

/// A span of detected speech, in seconds from the start of the audio.
struct SpeechRegion: Equatable {
    let start: Double
    let end: Double
}

/// Merges SentencePiece-style tokens into words.
///
/// Tokens use leading whitespace as word boundaries (normalised by `AsrManager`). A word's confidence is the mean
/// confidence of its tokens. Replicates `WordTimingMerger.mergeTokensIntoWords` from FluidAudioCLI, which the core
/// library does not export.
func mergeTokensIntoWords(_ tokenTimings: [TokenTiming]) -> [WordTiming] {
    var result: [WordTiming] = []
    var current: [TokenTiming] = []

    func flush() {
        let text = current.map(\.token).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = current.first, let last = current.last, !text.isEmpty {
            let confidence = current.map(\.confidence).reduce(0, +) / Float(current.count)
            result.append(
                WordTiming(word: text, start: first.startTime, end: last.endTime, confidence: confidence))
        }
        current.removeAll(keepingCapacity: true)
    }

    for timing in tokenTimings {
        if timing.token.first?.isWhitespace == true {
            flush()
        }
        current.append(timing)
    }
    flush()
    return result
}

/// Groups recognized words into transcript segments bounded by the detected speech regions.
///
/// Recognition runs once over the whole audio, so segmentation only decides presentation: each word joins the region
/// it overlaps most, or the nearest region when it falls in a gap (VAD boundaries are approximate). Regions that end
/// up without words produce no segment, so every segment carries text. A segment spans its region, widened to cover
/// all of its words.
func segmentWords(_ words: [WordTiming], into regions: [SpeechRegion]) -> [SegmentResult] {
    guard !regions.isEmpty else { return [] }
    var wordsByRegion = [[WordTiming]](repeating: [], count: regions.count)
    for word in words {
        wordsByRegion[closestRegionIndex(for: word, in: regions)].append(word)
    }

    return zip(regions, wordsByRegion).compactMap { region, regionWords in
        let ordered = regionWords.sorted { $0.start < $1.start }
        guard let first = ordered.first else { return nil }
        let end = max(region.end, ordered.map(\.end).max() ?? region.end)
        return SegmentResult(
            text: ordered.map(\.word).joined(separator: " "),
            start: min(region.start, first.start),
            end: end,
            words: ordered,
            confidence: ordered.map(\.confidence).reduce(0, +) / Float(ordered.count)
        )
    }
}

/// Index of the region a word overlaps most; when it overlaps none, the region with the smallest gap to it.
/// Ties go to the earlier region.
private func closestRegionIndex(for word: WordTiming, in regions: [SpeechRegion]) -> Int {
    var bestIndex = 0
    var bestScore = -Double.infinity
    for (index, region) in regions.enumerated() {
        let overlap = min(word.end, region.end) - max(word.start, region.start)
        // Positive overlap ranks above any gap; gaps rank by closeness (a negative overlap is minus the gap).
        if overlap > bestScore {
            bestScore = overlap
            bestIndex = index
        }
    }
    return bestIndex
}
