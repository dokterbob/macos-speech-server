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
