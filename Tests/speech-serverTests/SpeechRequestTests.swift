import XCTest

@testable import speech_server

final class SpeechRequestTests: XCTestCase {
    // MARK: - Resolved defaults

    func testDefaultVoice() {
        let req = SpeechRequest(model: "tts-1", input: "Hello", voice: nil, responseFormat: nil, speed: nil)
        XCTAssertEqual(req.resolvedVoice, "alba")
    }

    func testDefaultFormat() {
        let req = SpeechRequest(model: "tts-1", input: "Hello", voice: nil, responseFormat: nil, speed: nil)
        XCTAssertEqual(req.resolvedFormat, "wav")
    }

    func testDefaultSpeed() {
        let req = SpeechRequest(model: "tts-1", input: "Hello", voice: nil, responseFormat: nil, speed: nil)
        XCTAssertEqual(req.resolvedSpeed, 1.0, accuracy: 0.001)
    }

    // MARK: - Explicit values preserved

    func testExplicitVoice() {
        let req = SpeechRequest(model: "tts-1", input: "Hi", voice: "alba", responseFormat: nil, speed: nil)
        XCTAssertEqual(req.resolvedVoice, "alba")
    }

    func testExplicitFormat() {
        let req = SpeechRequest(model: "tts-1", input: "Hi", voice: nil, responseFormat: "pcm", speed: nil)
        XCTAssertEqual(req.resolvedFormat, "pcm")
    }

    func testExplicitSpeed() {
        let req = SpeechRequest(model: "tts-1", input: "Hi", voice: nil, responseFormat: nil, speed: 2.0)
        XCTAssertEqual(req.resolvedSpeed, 2.0, accuracy: 0.001)
    }

    func testExplicitSpeedAtMinimum() {
        let req = SpeechRequest(model: "tts-1", input: "Hi", voice: nil, responseFormat: nil, speed: 0.25)
        XCTAssertEqual(req.resolvedSpeed, 0.25, accuracy: 0.001)
    }

    func testExplicitSpeedAtMaximum() {
        let req = SpeechRequest(model: "tts-1", input: "Hi", voice: nil, responseFormat: nil, speed: 4.0)
        XCTAssertEqual(req.resolvedSpeed, 4.0, accuracy: 0.001)
    }
}
