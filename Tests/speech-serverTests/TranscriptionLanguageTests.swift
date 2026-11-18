import FluidAudio
import Vapor
import XCTest

@testable import speech_server

final class TranscriptionLanguageTests: XCTestCase {
    private let supported = ["en", "pl"]

    // MARK: - transcriptionLanguageHint

    func testOmittedOrAutoLanguageMeansAutomaticDetection() throws {
        XCTAssertNil(try transcriptionLanguageHint(nil, supported: supported))
        XCTAssertNil(try transcriptionLanguageHint("auto", supported: supported))
    }

    func testSupportedLanguageCodeIsNormalized() throws {
        XCTAssertEqual(try transcriptionLanguageHint("PL", supported: supported), "pl")
    }

    func testUnsupportedLanguageIsRejectedWithSupportedList() {
        for requested in ["xx", "", "en-US"] {
            XCTAssertThrowsError(try transcriptionLanguageHint(requested, supported: supported)) { error in
                let abort = error as? Abort
                XCTAssertEqual(abort?.status, .badRequest)
                XCTAssertTrue(abort?.reason.contains("auto, en, pl") == true, "\(abort?.reason ?? "")")
            }
        }
    }

    // MARK: - reportedLanguage

    func testReportedLanguagePrefersTheHint() {
        XCTAssertEqual(reportedLanguage(hint: "pl", transcript: "The quick brown fox jumps over the lazy dog."), "pl")
    }

    func testReportedLanguageIsDetectedFromTranscriptWithoutHint() {
        XCTAssertEqual(reportedLanguage(hint: nil, transcript: "The quick brown fox jumps over the lazy dog."), "en")
    }

    func testReportedLanguageIsUndeterminedForEmptyTranscript() {
        XCTAssertEqual(reportedLanguage(hint: nil, transcript: ""), "und")
    }

    // MARK: - Parakeet languages

    func testParakeetV2IsEnglishOnly() {
        XCTAssertEqual(FluidSTTService.languages(for: .v2), ["en"])
    }

    func testEveryParakeetV3LanguageIsAFluidAudioLanguageHint() {
        let languages = FluidSTTService.languages(for: .v3)
        XCTAssertEqual(languages.count, 25)
        XCTAssertEqual(FluidSTTService.languages(for: .ultra), languages)
        for code in languages {
            XCTAssertNotNil(Language(rawValue: code), "FluidAudio has no Language for '\(code)'")
        }
    }
}
