import XCTest

@testable import speech_server

final class WyomingSessionTests: XCTestCase {
    // MARK: - Helpers

    /// Collects all values from an AsyncStream into an array.
    private func collect(_ stream: AsyncStream<Data>) async -> [Data] {
        var results: [Data] = []
        for await data in stream { results.append(data) }
        return results
    }

    /// Concatenates response chunks and decodes them as Wyoming events.
    private func decodeEvents(from responses: [Data]) -> [WyomingEvent] {
        var decoder = WyomingFrameDecoder()
        return decoder.process(responses.reduce(Data(), +))
    }

    // MARK: - describe → info

    func testDescribeReturnsInfo() async throws {
        let session = WyomingSession(
            ttsService: MockTTSService(),
            sttService: MockSTTService()
        )
        let stream = await session.handle(event: WyomingEvent(type: "describe"))
        let responses = await collect(stream)
        XCTAssertEqual(responses.count, 1)

        let events = decodeEvents(from: responses)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].type, "info")
    }

    func testInfoContainsAsrAndTts() async throws {
        let session = WyomingSession(
            ttsService: MockTTSService(),
            sttService: MockSTTService()
        )
        let stream = await session.handle(event: WyomingEvent(type: "describe"))
        let responses = await collect(stream)
        let events = decodeEvents(from: responses)
        let info = events[0]

        // Must have both asr and tts arrays
        let asrArray = info.data["asr"]?.arrayValue
        let ttsArray = info.data["tts"]?.arrayValue
        XCTAssertNotNil(asrArray)
        XCTAssertNotNil(ttsArray)
        XCTAssertFalse(asrArray!.isEmpty)
        XCTAssertFalse(ttsArray!.isEmpty)

        // ASR program must have a "models" array (two-level hierarchy)
        let asrProgram = asrArray![0].objectValue
        XCTAssertNotNil(asrProgram)
        XCTAssertEqual(asrProgram?["installed"]?.boolValue, true)
        // languages must NOT be on the program — it lives on the model
        XCTAssertNil(asrProgram?["languages"])
        let asrModels = asrProgram?["models"]?.arrayValue
        XCTAssertNotNil(asrModels)
        XCTAssertFalse(asrModels!.isEmpty)
        let firstAsrModel = asrModels![0].objectValue
        XCTAssertNotNil(firstAsrModel)
        XCTAssertEqual(firstAsrModel?["installed"]?.boolValue, true)
        let asrModelLangs = firstAsrModel?["languages"]?.arrayValue
        XCTAssertNotNil(asrModelLangs)
        XCTAssertTrue(asrModelLangs!.contains(where: { $0.stringValue == "en" }))

        // TTS program must have a "voices" array; each voice has "languages"
        let ttsProgram = ttsArray![0].objectValue
        XCTAssertNotNil(ttsProgram)
        // languages must NOT be on the program — it lives on the voice
        XCTAssertNil(ttsProgram?["languages"])
        let voices = ttsProgram?["voices"]?.arrayValue
        XCTAssertNotNil(voices)
        XCTAssertFalse(voices!.isEmpty)
        let albaVoice = voices![0].objectValue
        XCTAssertEqual(albaVoice?["name"]?.stringValue, "alba")
        let voiceLangs = albaVoice?["languages"]?.arrayValue
        XCTAssertNotNil(voiceLangs)
        XCTAssertTrue(voiceLangs!.contains(where: { $0.stringValue == "en" }))

        // Empty arrays for unsupported services must be present
        XCTAssertEqual(info.data["handle"]?.arrayValue?.count, 0)
        XCTAssertEqual(info.data["intent"]?.arrayValue?.count, 0)
        XCTAssertEqual(info.data["wake"]?.arrayValue?.count, 0)
        XCTAssertEqual(info.data["mic"]?.arrayValue?.count, 0)
        XCTAssertEqual(info.data["snd"]?.arrayValue?.count, 0)
    }

    func testDescribeDoesNotChangeState() async throws {
        // After describe, the session should still handle a synthesize correctly
        let pcm = Data(repeating: 0xAB, count: 64)
        let session = WyomingSession(
            ttsService: MockTTSService(chunks: [pcm]),
            sttService: MockSTTService()
        )

        // describe first (discard stream — state is unchanged synchronously)
        _ = await session.handle(event: WyomingEvent(type: "describe"))

        // then synthesize — should still work
        let stream = await session.handle(
            event: WyomingEvent(
                type: "synthesize",
                data: ["text": .string("hello")]
            ))
        let responses = await collect(stream)
        XCTAssertFalse(responses.isEmpty)
    }

    // MARK: - synthesize → audio sequence

    func testSynthesizeReturnsAudioStartChunkStop() async throws {
        let pcm = Data(repeating: 0x42, count: 128)
        let session = WyomingSession(
            ttsService: MockTTSService(chunks: [pcm]),
            sttService: MockSTTService()
        )

        let stream = await session.handle(
            event: WyomingEvent(
                type: "synthesize",
                data: ["text": .string("Hello, world!")]
            ))
        let responses = await collect(stream)

        let events = decodeEvents(from: responses)

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

        let stream = await session.handle(
            event: WyomingEvent(
                type: "synthesize",
                data: ["text": .string("Two sentences. Here is one more.")]
            ))
        let responses = await collect(stream)
        let events = decodeEvents(from: responses)

        // audio-start + 2×audio-chunk + audio-stop = 4 events
        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(events[0].type, "audio-start")
        XCTAssertEqual(events[1].type, "audio-chunk")
        XCTAssertEqual(events[2].type, "audio-chunk")
        XCTAssertEqual(events[3].type, "audio-stop")
        XCTAssertEqual(events[1].payload, chunk1)
        XCTAssertEqual(events[2].payload, chunk2)
    }

    // MARK: - Streaming behaviour

    func testSynthesizeStreamsIncrementally() async throws {
        // Verify that audio-start arrives first, then each chunk, then audio-stop — in order,
        // without waiting for all chunks to be produced.
        let chunk1 = Data(repeating: 0x01, count: 64)
        let chunk2 = Data(repeating: 0x02, count: 64)
        let session = WyomingSession(
            ttsService: MockTTSService(chunks: [chunk1, chunk2]),
            sttService: MockSTTService()
        )

        var receivedEventTypes: [String] = []
        var decoder = WyomingFrameDecoder()

        for await data in await session.handle(
            event: WyomingEvent(
                type: "synthesize",
                data: ["text": .string("hello world")]
            ))
        {
            let events = decoder.process(data)
            for event in events {
                receivedEventTypes.append(event.type)
            }
        }

        // Verify ordering: audio-start, then two audio-chunks, then audio-stop
        XCTAssertEqual(receivedEventTypes, ["audio-start", "audio-chunk", "audio-chunk", "audio-stop"])
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
        let stream = await session.handle(
            event: WyomingEvent(
                type: "synthesize",
                data: ["text": .string("test")]
            ))
        let responses = await collect(stream)
        XCTAssertFalse(responses.isEmpty)
    }

    func testSynthesizeVoiceAsString() async throws {
        let session = WyomingSession(
            ttsService: MockTTSService(chunks: [Data([0x01])]),
            sttService: MockSTTService()
        )
        let stream = await session.handle(
            event: WyomingEvent(
                type: "synthesize",
                data: ["text": .string("test"), "voice": .string("alba")]
            ))
        let responses = await collect(stream)
        XCTAssertFalse(responses.isEmpty)
    }

    func testSynthesizeVoiceAsObject() async throws {
        let session = WyomingSession(
            ttsService: MockTTSService(chunks: [Data([0x01])]),
            sttService: MockSTTService()
        )
        let stream = await session.handle(
            event: WyomingEvent(
                type: "synthesize",
                data: [
                    "text": .string("test"),
                    "voice": .object(["name": .string("alba")]),
                ]
            ))
        let responses = await collect(stream)
        XCTAssertFalse(responses.isEmpty)
    }

    // MARK: - STT flow

    func testFullSTTFlow() async throws {
        let session = WyomingSession(
            ttsService: MockTTSService(),
            sttService: MockSTTService(transcript: "hello world")
        )

        // 1. transcribe — no response (state → awaitingAudio synchronously)
        let stream1 = await session.handle(event: WyomingEvent(type: "transcribe"))
        let r1 = await collect(stream1)
        XCTAssertTrue(r1.isEmpty)

        // 2. audio-start — no response
        let stream2 = await session.handle(
            event: WyomingEvent(
                type: "audio-start",
                data: ["rate": .int(16000), "width": .int(2), "channels": .int(1)]
            ))
        let r2 = await collect(stream2)
        XCTAssertTrue(r2.isEmpty)

        // 3. audio-chunk — no response (just buffering)
        let pcm = Data(repeating: 0xAB, count: 32000)  // 1 second of 16kHz 16-bit mono
        let stream3 = await session.handle(
            event: WyomingEvent(
                type: "audio-chunk",
                data: ["rate": .int(16000), "width": .int(2), "channels": .int(1)],
                payload: pcm
            ))
        let r3 = await collect(stream3)
        XCTAssertTrue(r3.isEmpty)

        // 4. audio-stop — should return transcript
        let stream4 = await session.handle(event: WyomingEvent(type: "audio-stop"))
        let r4 = await collect(stream4)
        XCTAssertEqual(r4.count, 1)

        let events = decodeEvents(from: r4)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].type, "transcript")
        XCTAssertEqual(events[0].data["text"]?.stringValue, "hello world")
    }

    func testSTTResetsToIdleAfterTranscript() async throws {
        let session = WyomingSession(
            ttsService: MockTTSService(chunks: [Data([0x01])]),
            sttService: MockSTTService(transcript: "done")
        )

        // Complete STT flow (state mutations are synchronous — discard streams)
        _ = await session.handle(event: WyomingEvent(type: "transcribe"))
        _ = await session.handle(
            event: WyomingEvent(
                type: "audio-start",
                data: ["rate": .int(16000), "width": .int(2), "channels": .int(1)]
            ))
        _ = await session.handle(
            event: WyomingEvent(
                type: "audio-chunk",
                data: ["rate": .int(16000), "width": .int(2), "channels": .int(1)],
                payload: Data(repeating: 0, count: 32000)
            ))
        _ = await session.handle(event: WyomingEvent(type: "audio-stop"))

        // Should now be back in idle — synthesize should work
        let stream = await session.handle(
            event: WyomingEvent(
                type: "synthesize",
                data: ["text": .string("hello")]
            ))
        let responses = await collect(stream)
        XCTAssertFalse(responses.isEmpty)
    }

    // MARK: - Error handling

    func testTTSErrorReturnsEmpty() async throws {
        let session = WyomingSession(
            ttsService: MockTTSService(shouldFail: true),
            sttService: MockSTTService()
        )
        let stream = await session.handle(
            event: WyomingEvent(
                type: "synthesize",
                data: ["text": .string("hello")]
            ))
        let responses = await collect(stream)
        // On TTS error, session returns empty (no crash)
        XCTAssertTrue(responses.isEmpty)
    }

    func testSTTErrorReturnsEmpty() async throws {
        let session = WyomingSession(
            ttsService: MockTTSService(),
            sttService: MockSTTService(shouldFail: true)
        )

        _ = await session.handle(event: WyomingEvent(type: "transcribe"))
        _ = await session.handle(
            event: WyomingEvent(
                type: "audio-start",
                data: ["rate": .int(16000), "width": .int(2), "channels": .int(1)]
            ))
        _ = await session.handle(
            event: WyomingEvent(
                type: "audio-chunk",
                data: ["rate": .int(16000), "width": .int(2), "channels": .int(1)],
                payload: Data(repeating: 0, count: 32000)
            ))
        let stream = await session.handle(event: WyomingEvent(type: "audio-stop"))
        let responses = await collect(stream)
        // On STT error, session returns empty (no crash), state resets to idle
        XCTAssertTrue(responses.isEmpty)
    }

    func testUnknownEventTypeReturnsEmpty() async throws {
        let session = WyomingSession(
            ttsService: MockTTSService(),
            sttService: MockSTTService()
        )
        let stream = await session.handle(event: WyomingEvent(type: "unknown-event-xyz"))
        let responses = await collect(stream)
        XCTAssertTrue(responses.isEmpty)
    }

    // MARK: - Streaming synthesis

    func testInfoAdvertisesStreamingSupport() async throws {
        let session = WyomingSession(
            ttsService: MockTTSService(),
            sttService: MockSTTService()
        )
        let stream = await session.handle(event: WyomingEvent(type: "describe"))
        let responses = await collect(stream)
        let events = decodeEvents(from: responses)
        let info = events[0]

        let ttsArray = info.data["tts"]?.arrayValue
        XCTAssertNotNil(ttsArray)
        let ttsProgram = ttsArray![0].objectValue
        XCTAssertNotNil(ttsProgram)
        XCTAssertEqual(ttsProgram?["supports_synthesize_streaming"]?.boolValue, true)
    }

    func testStreamingSynthesizeBasicFlow() async throws {
        let pcm = Data(repeating: 0xAB, count: 64)
        let session = WyomingSession(
            ttsService: MockTTSService(chunks: [pcm]),
            sttService: MockSTTService()
        )

        // synthesize-start: no audio, empty stream
        let r1 = await collect(
            await session.handle(
                event: WyomingEvent(
                    type: "synthesize-start",
                    data: ["voice": .string("alba")]
                )))
        XCTAssertTrue(r1.isEmpty)

        // synthesize-chunk with a complete sentence → audio produced
        let r2 = await collect(
            await session.handle(
                event: WyomingEvent(
                    type: "synthesize-chunk",
                    data: ["text": .string("Hello.")]
                )))

        // synthesize-stop with empty buffer → only synthesize-stopped
        let r3 = await collect(await session.handle(event: WyomingEvent(type: "synthesize-stop")))

        let events = decodeEvents(from: r2 + r3)

        // audio-start, audio-chunk, audio-stop, synthesize-stopped
        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(events[0].type, "audio-start")
        XCTAssertEqual(events[1].type, "audio-chunk")
        XCTAssertEqual(events[1].payload, pcm)
        XCTAssertEqual(events[2].type, "audio-stop")
        XCTAssertEqual(events[3].type, "synthesize-stopped")
    }

    func testStreamingSynthesizeMultipleSentences() async throws {
        let pcm = Data(repeating: 0x42, count: 32)
        let session = WyomingSession(
            ttsService: MockTTSService(chunks: [pcm]),
            sttService: MockSTTService()
        )

        _ = await collect(
            await session.handle(
                event: WyomingEvent(
                    type: "synthesize-start",
                    data: ["voice": .string("alba")]
                )))

        // First chunk: complete sentence
        let r2 = await collect(
            await session.handle(
                event: WyomingEvent(
                    type: "synthesize-chunk",
                    data: ["text": .string("Hello. ")]
                )))

        // Second chunk: another complete sentence
        let r3 = await collect(
            await session.handle(
                event: WyomingEvent(
                    type: "synthesize-chunk",
                    data: ["text": .string("World.")]
                )))

        let r4 = await collect(await session.handle(event: WyomingEvent(type: "synthesize-stop")))

        let events = decodeEvents(from: r2 + r3 + r4)

        // Two complete audio sequences + synthesize-stopped
        let types = events.map { $0.type }
        XCTAssertEqual(
            types,
            [
                "audio-start", "audio-chunk", "audio-stop",
                "audio-start", "audio-chunk", "audio-stop",
                "synthesize-stopped",
            ])
    }

    func testStreamingSynthesizeSentenceDetection() async throws {
        let pcm = Data(repeating: 0x33, count: 32)
        let session = WyomingSession(
            ttsService: MockTTSService(chunks: [pcm]),
            sttService: MockSTTService()
        )

        _ = await collect(
            await session.handle(
                event: WyomingEvent(
                    type: "synthesize-start",
                    data: ["voice": .string("alba")]
                )))

        // Chunk with one complete sentence and one incomplete fragment
        let r2 = await collect(
            await session.handle(
                event: WyomingEvent(
                    type: "synthesize-chunk",
                    data: ["text": .string("Hello world. This is")]
                )))

        // synthesize-stop: remaining "This is" should be synthesized
        let r3 = await collect(await session.handle(event: WyomingEvent(type: "synthesize-stop")))

        let events = decodeEvents(from: r2 + r3)

        // "Hello world." synthesized from chunk, "This is." synthesized at stop
        let types = events.map { $0.type }
        XCTAssertEqual(
            types,
            [
                "audio-start", "audio-chunk", "audio-stop",
                "audio-start", "audio-chunk", "audio-stop",
                "synthesize-stopped",
            ])
    }

    func testStreamingSynthesizeIgnoresBackwardCompatSynthesize() async throws {
        let pcm = Data(repeating: 0x01, count: 32)
        let session = WyomingSession(
            ttsService: MockTTSService(chunks: [pcm]),
            sttService: MockSTTService()
        )

        _ = await collect(
            await session.handle(
                event: WyomingEvent(
                    type: "synthesize-start",
                    data: ["voice": .string("alba")]
                )))
        _ = await collect(
            await session.handle(
                event: WyomingEvent(
                    type: "synthesize-chunk",
                    data: ["text": .string("Hello.")]
                )))

        // synthesize event during streaming mode must be ignored (backward compat)
        let rIgnored = await collect(
            await session.handle(
                event: WyomingEvent(
                    type: "synthesize",
                    data: ["text": .string("Full text here.")]
                )))
        XCTAssertTrue(rIgnored.isEmpty)

        // synthesize-stop should still finalise the streaming session
        let rStop = await collect(await session.handle(event: WyomingEvent(type: "synthesize-stop")))
        let events = decodeEvents(from: rStop)
        XCTAssertTrue(events.contains(where: { $0.type == "synthesize-stopped" }))
    }

    func testStreamingSynthesizeEmptyBuffer() async throws {
        let session = WyomingSession(
            ttsService: MockTTSService(chunks: []),
            sttService: MockSTTService()
        )

        _ = await collect(
            await session.handle(
                event: WyomingEvent(
                    type: "synthesize-start",
                    data: ["voice": .string("alba")]
                )))

        // synthesize-stop with no chunks → only synthesize-stopped, no audio
        let responses = await collect(await session.handle(event: WyomingEvent(type: "synthesize-stop")))

        let events = decodeEvents(from: responses)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].type, "synthesize-stopped")
    }

    func testStreamingSynthesizeError() async throws {
        let session = WyomingSession(
            ttsService: MockTTSService(shouldFail: true),
            sttService: MockSTTService()
        )

        _ = await collect(
            await session.handle(
                event: WyomingEvent(
                    type: "synthesize-start",
                    data: ["voice": .string("alba")]
                )))
        // TTS fails for this sentence but we don't crash
        let rChunk = await collect(
            await session.handle(
                event: WyomingEvent(
                    type: "synthesize-chunk",
                    data: ["text": .string("Hello.")]
                )))

        let rStop = await collect(await session.handle(event: WyomingEvent(type: "synthesize-stop")))

        let events = decodeEvents(from: rChunk + rStop)

        // No audio chunks since TTS failed, but synthesize-stopped must still arrive
        XCTAssertFalse(events.contains(where: { $0.type == "audio-chunk" }))
        XCTAssertTrue(events.contains(where: { $0.type == "synthesize-stopped" }))
    }

    func testStreamingSynthesizeResetsToIdle() async throws {
        let pcm = Data(repeating: 0x42, count: 32)
        let session = WyomingSession(
            ttsService: MockTTSService(chunks: [pcm]),
            sttService: MockSTTService()
        )

        // Complete streaming flow
        _ = await collect(
            await session.handle(
                event: WyomingEvent(
                    type: "synthesize-start",
                    data: ["voice": .string("alba")]
                )))
        _ = await collect(await session.handle(event: WyomingEvent(type: "synthesize-stop")))

        // State should be idle — regular synthesize must work
        let stream = await session.handle(
            event: WyomingEvent(
                type: "synthesize",
                data: ["text": .string("hello")]
            ))
        let responses = await collect(stream)
        XCTAssertFalse(responses.isEmpty)
    }

    // MARK: - Mixed TTS+STT on same session

    func testDescribeCanBeCalledDuringRecording() async throws {
        let session = WyomingSession(
            ttsService: MockTTSService(),
            sttService: MockSTTService(transcript: "hi")
        )

        _ = await session.handle(event: WyomingEvent(type: "transcribe"))
        _ = await session.handle(
            event: WyomingEvent(
                type: "audio-start",
                data: ["rate": .int(16000), "width": .int(2), "channels": .int(1)]
            ))

        // describe should work even during recording
        let stream = await session.handle(event: WyomingEvent(type: "describe"))
        let infoResponses = await collect(stream)
        XCTAssertEqual(infoResponses.count, 1)
        let events = decodeEvents(from: infoResponses)
        XCTAssertEqual(events[0].type, "info")
    }
}
