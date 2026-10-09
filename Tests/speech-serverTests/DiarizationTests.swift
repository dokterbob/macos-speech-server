import XCTest

@testable import speech_server

final class DiarizationTests: XCTestCase {
    private let turns = [
        SpeakerTurn(speaker: "speaker_0", start: 0, end: 2),
        SpeakerTurn(speaker: "speaker_1", start: 2, end: 4),
    ]

    func testWordAlignmentSplitsAtSpeakerChanges() {
        let words = [
            WordTiming(word: "Hello", start: 0.5, end: 1),
            WordTiming(word: "there.", start: 1, end: 1.5),
            WordTiming(word: "Hi!", start: 2.5, end: 3),
        ]
        let segments = alignSpeakers(
            segments: [SegmentResult(text: "Hello there. Hi!", start: 0, end: 4, words: words, confidence: 0.9)],
            turns: turns)
        XCTAssertEqual(segments.map(\.speaker), ["speaker_0", "speaker_1"])
        XCTAssertEqual(segments.map(\.text), ["Hello there.", "Hi!"])
        XCTAssertEqual(segments.map(\.start), [0.5, 2.5])
        XCTAssertEqual(segments.map(\.end), [1.5, 3])
    }

    func testSegmentFallbackAggregatesSpeakerOverlap() {
        let segments = alignSpeakers(
            segments: [SegmentResult(text: "Whole segment", start: 0, end: 5, words: [], confidence: 1)],
            turns: [
                SpeakerTurn(speaker: "a", start: 0, end: 1.5),
                SpeakerTurn(speaker: "b", start: 1.5, end: 4),
                SpeakerTurn(speaker: "a", start: 4, end: 5),
            ])
        XCTAssertEqual(segments.first?.speaker, "a")  // Tie goes to the first speaker chronologically.
        XCTAssertEqual(segments.first?.text, "Whole segment")
        XCTAssertEqual(segments.first?.end, 5)
    }

    func testUnmatchedSpeechIsUnknownAndTextIsRetained() {
        let input = SegmentResult(text: "Unmatched", start: 6, end: 7, words: [], confidence: 1)
        XCTAssertEqual(alignSpeakers(segments: [input], turns: turns).first?.speaker, "unknown")
        XCTAssertEqual(alignSpeakers(segments: [input], turns: []).first?.text, "Unmatched")
        XCTAssertTrue(alignSpeakers(segments: [], turns: turns).isEmpty)
    }

    func testBoundaryWordUsesGreatestOverlap() {
        let input = SegmentResult(
            text: "Boundary", start: 1, end: 3,
            words: [WordTiming(word: "Boundary", start: 1.9, end: 2.5)], confidence: 1)
        XCTAssertEqual(alignSpeakers(segments: [input], turns: turns.reversed()).first?.speaker, "speaker_1")
    }

    func testLazyModelsAreReusedAndConcurrentRequestsAreSerialized() async throws {
        let backend = TestDiarizationBackend()
        let service = FluidDiarizationService(makeBackend: { backend })
        let initial = await backend.counts()
        XCTAssertEqual(initial.prepares, 0)
        async let first = service.diarize(audioURL: URL(fileURLWithPath: "/tmp/first.wav"))
        async let second = service.diarize(audioURL: URL(fileURLWithPath: "/tmp/second.wav"))
        _ = try await (first, second)
        let counts = await backend.counts()
        XCTAssertEqual(counts.prepares, 1)
        XCTAssertEqual(counts.processes, 2)
        XCTAssertEqual(counts.peak, 1)
    }

    func testFailedLoadCanRetry() async throws {
        let backend = TestDiarizationBackend(failFirstLoad: true)
        let service = FluidDiarizationService(makeBackend: { backend })
        do {
            _ = try await service.diarize(audioURL: URL(fileURLWithPath: "/tmp/test.wav"))
            XCTFail("Expected model load failure")
        }
        catch MockServiceError.failed {}
        _ = try await service.diarize(audioURL: URL(fileURLWithPath: "/tmp/test.wav"))
        let counts = await backend.counts()
        XCTAssertEqual(counts.prepares, 2)
        XCTAssertEqual(counts.processes, 1)
    }

    func testInferenceFailureReleasesGateAndReusesModels() async throws {
        let backend = TestDiarizationBackend(failFirstProcess: true)
        let service = FluidDiarizationService(makeBackend: { backend })
        do {
            _ = try await service.diarize(audioURL: URL(fileURLWithPath: "/tmp/test.wav"))
            XCTFail("Expected inference failure")
        }
        catch MockServiceError.failed {}
        _ = try await service.diarize(audioURL: URL(fileURLWithPath: "/tmp/test.wav"))
        let counts = await backend.counts()
        XCTAssertEqual(counts.prepares, 1)
        XCTAssertEqual(counts.processes, 2)
    }

    func testVerboseResponseWithoutDiarizationOmitsSpeaker() throws {
        let segment = TranscriptionSegment(
            id: 0, seek: 0, start: 0, end: 1, text: "Hello", temperature: 0,
            avgLogprob: 0, compressionRatio: 1, noSpeechProb: 0)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(segment)) as? [String: Any]
        XCTAssertNil(json?["speaker"])
        XCTAssertEqual(json?["avg_logprob"] as? Double, 0)
    }
}

private actor TestDiarizationBackend: DiarizationBackend {
    private var prepares = 0
    private var processes = 0
    private var active = 0
    private var peak = 0
    private let failFirstLoad: Bool
    private let failFirstProcess: Bool

    init(failFirstLoad: Bool = false, failFirstProcess: Bool = false) {
        self.failFirstLoad = failFirstLoad
        self.failFirstProcess = failFirstProcess
    }

    func prepare() async throws {
        prepares += 1
        await Task.yield()
        if failFirstLoad && prepares == 1 { throw MockServiceError.failed }
    }

    func process(_ url: URL) async throws -> [SpeakerTurn] {
        processes += 1
        active += 1
        defer { active -= 1 }
        peak = max(peak, active)
        try await Task.sleep(for: .milliseconds(20))
        if failFirstProcess && processes == 1 { throw MockServiceError.failed }
        return []
    }

    func counts() -> (prepares: Int, processes: Int, peak: Int) { (prepares, processes, peak) }
}
