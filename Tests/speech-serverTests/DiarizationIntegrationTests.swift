import XCTest

@testable import speech_server

final class DiarizationIntegrationTests: XCTestCase {
    /// Opt in because this downloads and compiles additional Core ML models.
    /// The controller/alignment/lifecycle tests run without these models.
    func testCommunityPipelineFromAudioFile() async throws {
        guard ProcessInfo.processInfo.environment["TEST_DIARIZATION_MODELS"] == "1" else {
            throw XCTSkip("Set TEST_DIARIZATION_MODELS=1 to exercise Community-1 models.")
        }
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "test", withExtension: "wav", subdirectory: "Fixtures"))
        let service = FluidDiarizationService()
        let turns = try await service.diarize(audioURL: url)
        XCTAssertFalse(turns.isEmpty, "Speech fixture should produce at least one speaker turn")
        for turn in turns {
            XCTAssertFalse(turn.speaker.isEmpty)
            XCTAssertGreaterThanOrEqual(turn.start, 0)
            XCTAssertGreaterThan(turn.end, turn.start)
        }
    }
}
