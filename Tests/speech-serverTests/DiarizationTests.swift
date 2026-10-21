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
            turns: turns, duration: 4)
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
            ], duration: 5)
        XCTAssertEqual(segments.first?.speaker, "a")  // Tie goes to the first speaker chronologically.
        XCTAssertEqual(segments.first?.text, "Whole segment")
        XCTAssertEqual(segments.first?.end, 5)
    }

    func testUnmatchedSpeechIsUnknownAndTextIsRetained() {
        let input = SegmentResult(text: "Unmatched", start: 6, end: 7, words: [], confidence: 1)
        XCTAssertEqual(alignSpeakers(segments: [input], turns: turns, duration: 7).first?.speaker, "unknown")
        XCTAssertEqual(alignSpeakers(segments: [input], turns: [], duration: 7).first?.text, "Unmatched")
        XCTAssertTrue(alignSpeakers(segments: [], turns: turns, duration: 7).isEmpty)
    }

    func testBoundaryWordUsesGreatestOverlap() {
        let input = SegmentResult(
            text: "Boundary", start: 1, end: 3,
            words: [WordTiming(word: "Boundary", start: 1.9, end: 2.5)], confidence: 1)
        XCTAssertEqual(
            alignSpeakers(segments: [input], turns: turns.reversed(), duration: 3).first?.speaker, "speaker_1")
    }

    func testPaddedWordTimesAreClampedToSegmentAndRecording() {
        let input = SegmentResult(
            text: "Hi there", start: 0.1, end: 0.7,
            words: [
                WordTiming(word: "Hi", start: 0, end: 0.3),
                WordTiming(word: "there", start: 0.3, end: 1),
            ], confidence: 1)
        let aligned = alignSpeakers(
            segments: [input], turns: [SpeakerTurn(speaker: "a", start: 0, end: 1)], duration: 0.5)
        XCTAssertEqual(aligned.first?.start, 0.1)
        XCTAssertEqual(aligned.first?.end, 0.5)
        XCTAssertEqual(aligned.first?.text, "Hi there")
    }

    func testWordsEntirelyInPaddingKeepTextWithoutAssigningPaddingSpeaker() {
        let input = SegmentResult(
            text: "Hi extra", start: 0, end: 0.5,
            words: [
                WordTiming(word: "Hi", start: 0.1, end: 0.4),
                WordTiming(word: "extra", start: 0.7, end: 0.9),
            ], confidence: 1)
        let aligned = alignSpeakers(
            segments: [input],
            turns: [
                SpeakerTurn(speaker: "a", start: 0, end: 0.5),
                SpeakerTurn(speaker: "b", start: 0.5, end: 1),
            ], duration: 0.5)
        XCTAssertEqual(aligned.map(\.speaker), ["a", "unknown"])
        XCTAssertEqual(aligned.map(\.text), ["Hi", "extra"])
        XCTAssertEqual(aligned.last?.start, 0.5)
        XCTAssertEqual(aligned.last?.end, 0.5)
    }

    func testUntimedSegmentIsBoundedByRecordingDuration() {
        let input = SegmentResult(text: "Hi", start: -0.1, end: 0.8, words: [], confidence: 1)
        let aligned = alignSpeakers(segments: [input], turns: turns, duration: 0.5)
        XCTAssertEqual(aligned.first?.start, 0)
        XCTAssertEqual(aligned.first?.end, 0.5)
    }

    func testOverlappingWordTimesDoNotShortenGroupEnd() {
        let input = SegmentResult(
            text: "Hi there", start: 0, end: 1,
            words: [
                WordTiming(word: "Hi", start: 0.1, end: 0.8),
                WordTiming(word: "there", start: 0.2, end: 0.6),
            ], confidence: 1)
        let aligned = alignSpeakers(segments: [input], turns: turns, duration: 1)
        XCTAssertEqual(aligned.first?.end, 0.8)
    }

    func testQueuedCancellationReturnsBeforeActiveInferenceFinishes() async throws {
        let backend = BlockingDiarizationBackend()
        let service = FluidDiarizationService(makeBackend: { backend })
        let url = URL(fileURLWithPath: "/tmp/test.wav")
        let first = Task { try await service.diarize(audioURL: url) }
        await backend.waitUntilStarted()
        let canceled = expectation(description: "Canceled waiter completes while inference is blocked")
        let second = Task {
            defer { canceled.fulfill() }
            do {
                _ = try await service.diarize(audioURL: url)
                return false
            }
            catch is CancellationError { return true }
            catch { return false }
        }
        await Task.yield()
        let third = Task { try await service.diarize(audioURL: url) }
        await Task.yield()
        second.cancel()
        await fulfillment(of: [canceled], timeout: 1)
        let callsBeforeRelease = await backend.calls
        XCTAssertEqual(callsBeforeRelease, 1)
        // Always release the backend, even if the expectation failed, to avoid
        // leaving the test hung when running against the old implementation.
        await backend.finishFirst()
        _ = try await first.value
        let wasCanceled = await second.value
        XCTAssertTrue(wasCanceled)
        _ = try await third.value
        let finalCalls = await backend.calls
        XCTAssertEqual(finalCalls, 2)
        let overlapped = await backend.enteredBeforeFirstFinished
        XCTAssertFalse(overlapped, "Canceling a waiter must not let another request bypass active inference")
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

private actor BlockingDiarizationBackend: DiarizationBackend {
    var calls = 0
    var enteredBeforeFirstFinished = false
    private var firstInference: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func prepare() async throws {}

    func process(_ url: URL) async throws -> [SpeakerTurn] {
        calls += 1
        if calls > 1 && firstInference != nil { enteredBeforeFirstFinished = true }
        if calls == 1 {
            await withCheckedContinuation { continuation in
                firstInference = continuation
                for waiter in startWaiters { waiter.resume() }
                startWaiters.removeAll()
            }
        }
        return []
    }

    func waitUntilStarted() async {
        if firstInference != nil { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finishFirst() {
        firstInference?.resume()
        firstInference = nil
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
