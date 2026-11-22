import XCTest

import struct FluidAudio.TokenTiming

@testable import speech_server

final class TranscriptSegmentationTests: XCTestCase {
    private func token(_ text: String, _ start: Double, _ end: Double, confidence: Float = 1.0) -> TokenTiming {
        TokenTiming(token: text, tokenId: 0, startTime: start, endTime: end, confidence: confidence)
    }

    private func word(_ text: String, _ start: Double, _ end: Double, confidence: Float = 1.0) -> WordTiming {
        WordTiming(word: text, start: start, end: end, confidence: confidence)
    }

    // MARK: - mergeTokensIntoWords

    func testMergeTokensJoinsSubwordsAndAveragesConfidence() {
        let words = mergeTokensIntoWords([
            token(" Hello", 0.0, 0.4, confidence: 0.9),
            token(" wor", 0.5, 0.7, confidence: 0.8),
            token("ld", 0.7, 0.9, confidence: 0.6),
            token(".", 0.9, 1.0, confidence: 1.0),
        ])

        XCTAssertEqual(words.map(\.word), ["Hello", "world."])
        XCTAssertEqual(words[1].start, 0.5)
        XCTAssertEqual(words[1].end, 1.0)
        XCTAssertEqual(words[1].confidence, 0.8, accuracy: 0.0001)
    }

    func testMergeTokensWithoutLeadingSpaceStartsFirstWord() {
        let words = mergeTokensIntoWords([token("Hi", 0.0, 0.2), token(" there", 0.3, 0.6)])
        XCTAssertEqual(words.map(\.word), ["Hi", "there"])
    }

    func testMergeTokensEmpty() {
        XCTAssertTrue(mergeTokensIntoWords([]).isEmpty)
    }

    // MARK: - segmentWords

    func testWordsAreGroupedIntoTheSpeechRegionsTheyOverlap() {
        let segments = segmentWords(
            [
                word("Please", 1.5, 1.9), word("send", 2.0, 2.2), word("the", 2.3, 2.7),
                word("reading", 4.8, 5.2), word("material.", 5.3, 5.9),
            ],
            into: [SpeechRegion(start: 1.4, end: 3.7), SpeechRegion(start: 4.7, end: 11.4)]
        )

        XCTAssertEqual(segments.map(\.text), ["Please send the", "reading material."])
        XCTAssertEqual(segments.map(\.start), [1.4, 4.7])
        XCTAssertEqual(segments.map(\.end), [3.7, 11.4])
        XCTAssertEqual(segments[0].words.count, 3)
    }

    func testSpeechRegionsWithoutRecognizedWordsProduceNoSegment() {
        let segments = segmentWords(
            [word("Hello", 4.8, 5.2)],
            into: [SpeechRegion(start: 1.4, end: 3.7), SpeechRegion(start: 4.7, end: 6.0)]
        )

        XCTAssertEqual(segments.map(\.text), ["Hello"])
    }

    func testWordsOutsideEveryRegionJoinTheNearestRegionAndWidenIt() {
        let segments = segmentWords(
            [word("Early", 0.2, 0.5), word("mid", 3.8, 4.0), word("late", 9.0, 9.4)],
            into: [SpeechRegion(start: 1.0, end: 3.0), SpeechRegion(start: 5.0, end: 8.0)]
        )

        XCTAssertEqual(segments.map(\.text), ["Early mid", "late"])
        XCTAssertEqual(segments[0].start, 0.2)
        XCTAssertEqual(segments[0].end, 4.0)
        XCTAssertEqual(segments[1].end, 9.4)
    }

    func testWordSpanningTwoRegionsJoinsTheOneItOverlapsMost() {
        let segments = segmentWords(
            [word("bridge", 2.8, 3.6)],
            into: [SpeechRegion(start: 1.0, end: 3.0), SpeechRegion(start: 3.1, end: 6.0)]
        )

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].start, 2.8)
        XCTAssertEqual(segments[0].end, 6.0)
    }

    func testSegmentConfidenceIsMeanOfWordConfidences() {
        let segments = segmentWords(
            [word("a", 0.1, 0.2, confidence: 0.5), word("b", 0.3, 0.4, confidence: 1.0)],
            into: [SpeechRegion(start: 0.0, end: 1.0)]
        )

        XCTAssertEqual(segments[0].confidence, 0.75, accuracy: 0.0001)
    }
}
