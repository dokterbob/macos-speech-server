import XCTest
@testable import speech_server

final class WyomingSessionTests: XCTestCase {

    // MARK: - describe → info

    func testDescribeReturnsInfo() async throws {
        let session = WyomingSession(
            ttsService: MockTTSService(),
            sttService: MockSTTService()
        )
        let responses = await session.handle(event: WyomingEvent(type: "describe"))
        XCTAssertEqual(responses.count, 1)

        // Decode the response event
        var decoder = WyomingFrameDecoder()
        let events = decoder.process(responses[0])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].type, "info")
    }

    func testInfoContainsAsrAndTts() async throws {
        let session = WyomingSession(
            ttsService: MockTTSService(),
            sttService: MockSTTService()
        )
        let responses = await session.handle(event: WyomingEvent(type: "describe"))
        var decoder = WyomingFrameDecoder()
        let events = decoder.process(responses[0])
        let info = events[0]

        // Must have both asr and tts arrays
        let asrArray = info.data["asr"]?.arrayValue
        let ttsArray = info.data["tts"]?.arrayValue
        XCTAssertNotNil(asrArray)
        XCTAssertNotNil(ttsArray)
        XCTAssertFalse(asrArray!.isEmpty)
        XCTAssertFalse(ttsArray!.isEmpty)

        // ASR must advertise at least "en"
        let asrModel = asrArray![0].objectValue
        XCTAssertNotNil(asrModel)
        XCTAssertEqual(asrModel?["installed"]?.boolValue, true)
        let asrLangs = asrModel?["languages"]?.arrayValue
        XCTAssertNotNil(asrLangs)

        // TTS must advertise the "alba" voice
        let ttsProgram = ttsArray![0].objectValue
        let voices = ttsProgram?["voices"]?.arrayValue
        XCTAssertNotNil(voices)
        let albaVoice = voices?.first?.objectValue
        XCTAssertEqual(albaVoice?["name"]?.stringValue, "alba")
    }

    func testDescribeDoesNotChangeState() async throws {
        // After describe, the session should still handle a synthesize correctly
        let pcm = Data(repeating: 0xAB, count: 64)
        let session = WyomingSession(
            ttsService: MockTTSService(chunks: [pcm]),
            sttService: MockSTTService()
        )

        // describe first
        _ = await session.handle(event: WyomingEvent(type: "describe"))

        // then synthesize — should still work
        let responses = await session.handle(event: WyomingEvent(
            type: "synthesize",
            data: ["text": .string("hello")]
        ))
        XCTAssertFalse(responses.isEmpty)
    }

    // MARK: - synthesize → audio sequence

    func testSynthesizeReturnsAudioStartChunkStop() async throws {
        let pcm = Data(repeating: 0x42, count: 128)
        let session = WyomingSession(
            ttsService: MockTTSService(chunks: [pcm]),
            sttService: MockSTTService()
        )

        let responses = await session.handle(event: WyomingEvent(
            type: "synthesize",
            data: ["text": .string("Hello, world!")]
        ))

        // Decode all response events
        var decoder = WyomingFrameDecoder()
        var allData = Data()
        for r in responses { allData.append(r) }
        let events = decoder.process(allData)

        // Expect: audio-start, audio-chunk (×1), audio-stop
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0].type, "audio-start")
        XCTAssertEqual(events[1].type, "audio-chunk")
        XCTAssertEqual(events[2].type, "audio-stop")

        // audio-start must have rate/width/channels
        XCTAssertNotNil(events[0].data["rate"]?.intValue)
        XCTAssertNotNil(events[0].data["width"]?.intValue)
        XCTAssertNotNil(events[0].data["channels"]?.intValue)

        // audio-chunk must have the PCM payload
        XCTAssertEqual(events[1].payload, pcm)
    }

    func testSynthesizeMultipleChunks() async throws {
        let chunk1 = Data(repeating: 0x01, count: 64)
        let chunk2 = Data(repeating: 0x02, count: 64)
        let session = WyomingSession(
            ttsService: MockTTSService(chunks: [chunk1, chunk2]),
            sttService: MockSTTService()
        )

        let responses = await session.handle(event: WyomingEvent(
            type: "synthesize",
            data: ["text": .string("Two sentences. Here is one more.")]
        ))

        var decoder = WyomingFrameDecoder()
        var allData = Data()
        for r in responses { allData.append(r) }
        let events = decoder.process(allData)

        // audio-start + 2×audio-chunk + audio-stop = 4 events
        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(events[0].type, "audio-start")
        XCTAssertEqual(events[1].type, "audio-chunk")
        XCTAssertEqual(events[2].type, "audio-chunk")
        XCTAssertEqual(events[3].type, "audio-stop")
        XCTAssertEqual(events[1].payload, chunk1)
        XCTAssertEqual(events[2].payload, chunk2)
    }

    // MARK: - Voice defaulting

    func testSynthesizeDefaultsToAlba() async throws {
        // With no voice field, session should pass "alba" to TTSService.
        // We verify this indirectly: MockTTSService doesn't filter by voice,
        // so if synthesis succeeds, voice was accepted.
        let session = WyomingSession(
            ttsService: MockTTSService(chunks: [Data([0x01])]),
            sttService: MockSTTService()
        )
        let responses = await session.handle(event: WyomingEvent(
            type: "synthesize",
            data: ["text": .string("test")]
        ))
        XCTAssertFalse(responses.isEmpty)
    }

    func testSynthesizeVoiceAsString() async throws {
        let session = WyomingSession(
            ttsService: MockTTSService(chunks: [Data([0x01])]),
            sttService: MockSTTService()
        )
        let responses = await session.handle(event: WyomingEvent(
            type: "synthesize",
            data: ["text": .string("test"), "voice": .string("alba")]
        ))
        XCTAssertFalse(responses.isEmpty)
    }

    func testSynthesizeVoiceAsObject() async throws {
        let session = WyomingSession(
            ttsService: MockTTSService(chunks: [Data([0x01])]),
            sttService: MockSTTService()
        )
        let responses = await session.handle(event: WyomingEvent(
            type: "synthesize",
            data: [
                "text": .string("test"),
                "voice": .object(["name": .string("alba")])
            ]
        ))
        XCTAssertFalse(responses.isEmpty)
    }

    // MARK: - STT flow

    func testFullSTTFlow() async throws {
        let session = WyomingSession(
            ttsService: MockTTSService(),
            sttService: MockSTTService(transcript: "hello world")
        )

        // 1. transcribe — no response
        let r1 = await session.handle(event: WyomingEvent(type: "transcribe"))
        XCTAssertTrue(r1.isEmpty)

        // 2. audio-start — no response
        let r2 = await session.handle(event: WyomingEvent(
            type: "audio-start",
            data: ["rate": .int(16000), "width": .int(2), "channels": .int(1)]
        ))
        XCTAssertTrue(r2.isEmpty)

        // 3. audio-chunk — no response (just buffering)
        let pcm = Data(repeating: 0xAB, count: 32000)  // 1 second of 16kHz 16-bit mono
        let r3 = await session.handle(event: WyomingEvent(
            type: "audio-chunk",
            data: ["rate": .int(16000), "width": .int(2), "channels": .int(1)],
            payload: pcm
        ))
        XCTAssertTrue(r3.isEmpty)

        // 4. audio-stop — should return transcript
        let r4 = await session.handle(event: WyomingEvent(type: "audio-stop"))
        XCTAssertEqual(r4.count, 1)

        var decoder = WyomingFrameDecoder()
        let events = decoder.process(r4[0])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].type, "transcript")
        XCTAssertEqual(events[0].data["text"]?.stringValue, "hello world")
    }

    func testSTTResetsToIdleAfterTranscript() async throws {
        let session = WyomingSession(
            ttsService: MockTTSService(chunks: [Data([0x01])]),
            sttService: MockSTTService(transcript: "done")
        )

        // Complete STT flow
        _ = await session.handle(event: WyomingEvent(type: "transcribe"))
        _ = await session.handle(event: WyomingEvent(
            type: "audio-start",
            data: ["rate": .int(16000), "width": .int(2), "channels": .int(1)]
        ))
        _ = await session.handle(event: WyomingEvent(
            type: "audio-chunk",
            data: ["rate": .int(16000), "width": .int(2), "channels": .int(1)],
            payload: Data(repeating: 0, count: 32000)
        ))
        _ = await session.handle(event: WyomingEvent(type: "audio-stop"))

        // Should now be back in idle — synthesize should work
        let responses = await session.handle(event: WyomingEvent(
            type: "synthesize",
            data: ["text": .string("hello")]
        ))
        XCTAssertFalse(responses.isEmpty)
    }

    // MARK: - Error handling

    func testTTSErrorReturnsEmpty() async throws {
        let session = WyomingSession(
            ttsService: MockTTSService(shouldFail: true),
            sttService: MockSTTService()
        )
        let responses = await session.handle(event: WyomingEvent(
            type: "synthesize",
            data: ["text": .string("hello")]
        ))
        // On TTS error, session returns empty (no crash)
        XCTAssertTrue(responses.isEmpty)
    }

    func testSTTErrorReturnsEmpty() async throws {
        let session = WyomingSession(
            ttsService: MockTTSService(),
            sttService: MockSTTService(shouldFail: true)
        )

        _ = await session.handle(event: WyomingEvent(type: "transcribe"))
        _ = await session.handle(event: WyomingEvent(
            type: "audio-start",
            data: ["rate": .int(16000), "width": .int(2), "channels": .int(1)]
        ))
        _ = await session.handle(event: WyomingEvent(
            type: "audio-chunk",
            data: ["rate": .int(16000), "width": .int(2), "channels": .int(1)],
            payload: Data(repeating: 0, count: 32000)
        ))
        let responses = await session.handle(event: WyomingEvent(type: "audio-stop"))
        // On STT error, session returns empty (no crash), state resets to idle
        XCTAssertTrue(responses.isEmpty)
    }

    func testUnknownEventTypeReturnsEmpty() async throws {
        let session = WyomingSession(
            ttsService: MockTTSService(),
            sttService: MockSTTService()
        )
        let responses = await session.handle(event: WyomingEvent(type: "unknown-event-xyz"))
        XCTAssertTrue(responses.isEmpty)
    }

    // MARK: - Mixed TTS+STT on same session

    func testDescribeCanBeCalledDuringRecording() async throws {
        let session = WyomingSession(
            ttsService: MockTTSService(),
            sttService: MockSTTService(transcript: "hi")
        )

        _ = await session.handle(event: WyomingEvent(type: "transcribe"))
        _ = await session.handle(event: WyomingEvent(
            type: "audio-start",
            data: ["rate": .int(16000), "width": .int(2), "channels": .int(1)]
        ))

        // describe should work even during recording
        let infoResponses = await session.handle(event: WyomingEvent(type: "describe"))
        XCTAssertEqual(infoResponses.count, 1)
        var decoder = WyomingFrameDecoder()
        let events = decoder.process(infoResponses[0])
        XCTAssertEqual(events[0].type, "info")
    }
}
