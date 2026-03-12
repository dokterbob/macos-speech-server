import XCTest

@testable import speech_server

final class SentenceDetectionTests: XCTestCase {
    // MARK: - detectSentences

    func testDetectSentencesBasic() {
        let result = detectSentences("Hello world.")
        XCTAssertEqual(result, ["Hello world."])
    }

    func testDetectSentencesMultiple() {
        let result = detectSentences("Hello. World!")
        XCTAssertEqual(result, ["Hello.", "World!"])
    }

    func testDetectSentencesAddsPeriod() {
        let result = detectSentences("Hello world")
        XCTAssertEqual(result, ["Hello world."])
    }

    func testDetectSentencesQuestionMark() {
        XCTAssertEqual(detectSentences("Who are you?"), ["Who are you?"])
    }

    func testDetectSentencesExclamation() {
        XCTAssertEqual(detectSentences("Watch out!"), ["Watch out!"])
    }

    func testDetectSentencesThreeSentences() {
        let result = detectSentences("One. Two! Three?")
        XCTAssertEqual(result, ["One.", "Two!", "Three?"])
    }

    func testDetectSentencesWhitespaceOnly() {
        // Whitespace-only input should produce a single sentence with a period appended
        // (the impl normalises and returns a non-empty result rather than crashing)
        let result = detectSentences("   ")
        XCTAssertFalse(result.isEmpty)
    }

    func testDetectSentencesEmptyString() {
        // Empty string: either empty array or a single empty-ish sentence — must not crash
        XCTAssertNoThrow(detectSentences(""))
    }

    // MARK: - splitCompleteSentences

    func testSplitCompleteSentencesWithRemainder() {
        let (complete, remainder) = splitCompleteSentences("Hello world. This is")
        XCTAssertEqual(complete, ["Hello world."])
        XCTAssertEqual(remainder, "This is")
    }

    func testSplitCompleteSentencesAllComplete() {
        let (complete, remainder) = splitCompleteSentences("Hello. World!")
        XCTAssertEqual(complete, ["Hello.", "World!"])
        XCTAssertEqual(remainder, "")
    }

    func testSplitCompleteSentencesEmpty() {
        let (complete, remainder) = splitCompleteSentences("")
        XCTAssertEqual(complete, [])
        XCTAssertEqual(remainder, "")
    }
}
