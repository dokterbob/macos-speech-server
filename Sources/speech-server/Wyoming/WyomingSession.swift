import Foundation
import Logging

/// Handles a single Wyoming protocol TCP connection, dispatching events to TTS and STT services.
///
/// State machine:
/// ```
/// idle ──synthesize──→ [call TTSService.synthesizeStream, send audio-start/chunk/stop] ──→ idle
/// idle ──synthesize-start──→ streamingSynthesize(voice, "")
/// streamingSynthesize ──synthesize-chunk──→ [detect sentences, send audio per sentence] ──→ streamingSynthesize(voice, remainder)
/// streamingSynthesize ──synthesize──→ [ignored, backward compat] (state unchanged)
/// streamingSynthesize ──synthesize-stop──→ [synthesize remaining buffer, send audio + synthesize-stopped] ──→ idle
/// idle ──transcribe──→ awaitingAudio
/// awaitingAudio ──audio-start──→ recording(WAVWriter)
/// recording ──audio-chunk──→ recording (append PCM)
/// recording ──audio-stop──→ [call STTService.transcribe, send transcript] ──→ idle
/// any state ──describe──→ [send info with both asr + tts capabilities] (state unchanged)
/// ```
actor WyomingSession {
    private let ttsService: any TTSService
    private let sttService: any STTService
    private var state: State = .idle
    private let logger: Logger

    private enum State {
        case idle
        case awaitingAudio
        case recording(writer: WyomingWAVWriter, rate: Int, width: Int, channels: Int)
        case streamingSynthesize(voice: String, textBuffer: String)
    }

    init(ttsService: any TTSService, sttService: any STTService, logger: Logger = Logger(label: "WyomingSession")) {
        self.ttsService = ttsService
        self.sttService = sttService
        self.logger = logger
    }

    /// Handle an incoming Wyoming event. Returns a stream of serialized wire bytes for response events.
    ///
    /// For `synthesize` events, bytes are yielded incrementally as TTS chunks arrive (audio-start,
    /// then each audio-chunk, then audio-stop). For all other events, any response bytes are
    /// pre-buffered and the stream finishes quickly. State mutations always happen synchronously
    /// before the stream is returned.
    func handle(event: WyomingEvent) -> AsyncStream<Data> {
        switch event.type {
        case "describe":
            logger.notice("Wyoming: describe received, sending info")
            let data = makeInfoEvent().serialize()
            return AsyncStream { continuation in
                continuation.yield(data)
                continuation.finish()
            }

        case "synthesize":
            // Ignore during streaming synthesis (backward compat with clients that send
            // synthesize after synthesize-start/chunk for the full text)
            if case .streamingSynthesize = state {
                logger.notice("Wyoming: synthesize received during streaming, ignoring (backward compat)")
                return AsyncStream { continuation in continuation.finish() }
            }
            let text = event.data["text"]?.stringValue ?? ""
            logger.notice("Wyoming: synthesize received, text='\(text.prefix(60))'")
            let voice = resolveVoice(from: event)
            return AsyncStream { continuation in
                Task {
                    await self.streamSynthesize(text: text, voice: voice, continuation: continuation)
                    continuation.finish()
                }
            }

        case "synthesize-start":
            guard case .idle = state else {
                logger.warning("Wyoming: synthesize-start received in unexpected state, ignoring")
                return AsyncStream { continuation in continuation.finish() }
            }
            let voice = resolveVoice(from: event)
            logger.notice("Wyoming: synthesize-start received, voice='\(voice)'")
            state = .streamingSynthesize(voice: voice, textBuffer: "")
            return AsyncStream { continuation in continuation.finish() }

        case "synthesize-chunk":
            guard case .streamingSynthesize(let voice, let buffer) = state else {
                logger.warning("Wyoming: synthesize-chunk received in unexpected state, ignoring")
                return AsyncStream { continuation in continuation.finish() }
            }
            let newText = event.data["text"]?.stringValue ?? ""
            let combined = buffer + newText
            let (completeSentences, remainder) = splitCompleteSentences(combined)
            state = .streamingSynthesize(voice: voice, textBuffer: remainder)

            guard !completeSentences.isEmpty else {
                return AsyncStream { continuation in continuation.finish() }
            }
            logger.notice("Wyoming: synthesize-chunk detected \(completeSentences.count) complete sentence(s)")
            return AsyncStream { continuation in
                Task {
                    await self.streamSentences(completeSentences, voice: voice, continuation: continuation)
                    continuation.finish()
                }
            }

        case "synthesize-stop":
            guard case .streamingSynthesize(let voice, let buffer) = state else {
                logger.warning("Wyoming: synthesize-stop received in unexpected state, ignoring")
                return AsyncStream { continuation in continuation.finish() }
            }
            state = .idle
            let remainingText = buffer.trimmingCharacters(in: .whitespaces)
            logger.notice("Wyoming: synthesize-stop received, remaining='\(remainingText.prefix(60))'")
            return AsyncStream { continuation in
                Task {
                    if !remainingText.isEmpty {
                        await self.streamSentences([remainingText], voice: voice, continuation: continuation)
                    }
                    continuation.yield(WyomingEvent(type: "synthesize-stopped").serialize())
                    continuation.finish()
                }
            }

        case "transcribe":
            logger.notice("Wyoming: transcribe received, awaiting audio")
            state = .awaitingAudio
            return AsyncStream { continuation in continuation.finish() }

        case "audio-start":
            logger.notice("Wyoming: audio-start received")
            applyAudioStart(event: event)
            return AsyncStream { continuation in continuation.finish() }

        case "audio-chunk":
            applyAudioChunk(event: event)
            return AsyncStream { continuation in continuation.finish() }

        case "audio-stop":
            logger.notice("Wyoming: audio-stop received, transcribing")
            guard case .recording(let writer, _, _, _) = state else {
                state = .idle
                return AsyncStream { continuation in continuation.finish() }
            }
            state = .idle
            return AsyncStream { continuation in
                Task {
                    await self.streamSTTResult(writer: writer, continuation: continuation)
                    continuation.finish()
                }
            }

        default:
            logger.warning("Unknown Wyoming event type: \(event.type)")
            return AsyncStream { continuation in continuation.finish() }
        }
    }

    // MARK: - Private helpers

    private func resolveVoice(from event: WyomingEvent) -> String {
        if let voiceStr = event.data["voice"]?.stringValue {
            return voiceStr
        }
        else if case .object(let voiceObj) = event.data["voice"],
            let voiceName = voiceObj["name"]?.stringValue
        {
            return voiceName
        }
        return ttsService.defaultVoice
    }

    private func applyAudioStart(event: WyomingEvent) {
        guard case .awaitingAudio = state else {
            logger.warning("audio-start received in unexpected state, ignoring")
            return
        }
        let rate = event.data["rate"]?.intValue ?? 16000
        let width = event.data["width"]?.intValue ?? 2
        let channels = event.data["channels"]?.intValue ?? 1
        let writer = WyomingWAVWriter(
            sampleRate: rate,
            channels: channels,
            bitsPerSample: width * 8
        )
        state = .recording(writer: writer, rate: rate, width: width, channels: channels)
    }

    private func applyAudioChunk(event: WyomingEvent) {
        guard case .recording(var writer, let rate, let width, let channels) = state else {
            return
        }
        if let pcm = event.payload {
            writer.append(pcm)
        }
        state = .recording(writer: writer, rate: rate, width: width, channels: channels)
    }

    /// Synthesize `text` as a single unit (non-streaming path), yielding audio-start / chunk(s) / audio-stop.
    private func streamSynthesize(text: String, voice: String, continuation: AsyncStream<Data>.Continuation) async {
        guard !text.isEmpty else {
            logger.warning("synthesize event missing text")
            return
        }

        let rate = ttsService.sampleRate
        let width = 2
        let channels = 1
        var chunkCount = 0

        do {
            // Delay audio-start until the first chunk arrives so that a completely
            // failed or empty synthesis sends no audio events at all.
            for try await chunk in ttsService.synthesizeStream(text: text, voice: voice) {
                if chunkCount == 0 {
                    let audioStart = WyomingEvent(
                        type: "audio-start",
                        data: [
                            "rate": .int(rate),
                            "width": .int(width),
                            "channels": .int(channels),
                        ]
                    )
                    continuation.yield(audioStart.serialize())
                }
                let audioChunk = WyomingEvent(
                    type: "audio-chunk",
                    data: [
                        "rate": .int(rate),
                        "width": .int(width),
                        "channels": .int(channels),
                    ],
                    payload: chunk
                )
                continuation.yield(audioChunk.serialize())
                chunkCount += 1
            }

            if chunkCount > 0 {
                continuation.yield(WyomingEvent(type: "audio-stop").serialize())
            }
            logger.notice("Wyoming: synthesize complete, \(chunkCount) chunk(s)")
        }
        catch {
            logger.error("TTS error during synthesize: \(error)")
            // If synthesis failed mid-stream, close the open audio sequence.
            if chunkCount > 0 {
                continuation.yield(WyomingEvent(type: "audio-stop").serialize())
            }
        }
    }

    /// Synthesize each sentence in `sentences` individually, yielding one complete
    /// audio-start / audio-chunk(s) / audio-stop sequence per sentence.
    ///
    /// Errors from individual sentences are logged and skipped; remaining sentences
    /// continue to be synthesized. This is used by both synthesize-chunk (for
    /// detected complete sentences) and synthesize-stop (for the remaining buffer).
    private func streamSentences(
        _ sentences: [String], voice: String, continuation: AsyncStream<Data>.Continuation
    ) async {
        let rate = ttsService.sampleRate
        let width = 2
        let channels = 1

        for sentence in sentences {
            var chunkCount = 0
            do {
                for try await chunk in ttsService.synthesizeStream(text: sentence, voice: voice) {
                    if chunkCount == 0 {
                        continuation.yield(
                            WyomingEvent(
                                type: "audio-start",
                                data: [
                                    "rate": .int(rate),
                                    "width": .int(width),
                                    "channels": .int(channels),
                                ]
                            ).serialize())
                    }
                    continuation.yield(
                        WyomingEvent(
                            type: "audio-chunk",
                            data: [
                                "rate": .int(rate),
                                "width": .int(width),
                                "channels": .int(channels),
                            ],
                            payload: chunk
                        ).serialize())
                    chunkCount += 1
                }
                if chunkCount > 0 {
                    continuation.yield(WyomingEvent(type: "audio-stop").serialize())
                }
            }
            catch {
                logger.error("TTS error for sentence '\(sentence.prefix(60))': \(error)")
                if chunkCount > 0 {
                    continuation.yield(WyomingEvent(type: "audio-stop").serialize())
                }
                // Continue to next sentence
            }
        }
    }

    private func streamSTTResult(writer: WyomingWAVWriter, continuation: AsyncStream<Data>.Continuation) async {
        do {
            let audioURL = try writer.writeToTempFile()
            defer { try? FileManager.default.removeItem(at: audioURL) }

            let result = try await sttService.transcribe(audioURL: audioURL)
            logger.notice("Wyoming: transcription result='\(result.text)'")
            let transcript = WyomingEvent(
                type: "transcript",
                data: ["text": .string(result.text)]
            )
            continuation.yield(transcript.serialize())
        }
        catch {
            logger.error("STT error during audio-stop: \(error)")
        }
    }

    // MARK: - Info event

    private func makeInfoEvent() -> WyomingEvent {
        let asrAttribution = WyomingValue.object([
            "name": .string("FluidAudio"),
            "url": .string("https://github.com/FluidInference/FluidAudio"),
        ])

        // Two-level ASR hierarchy: AsrProgram → models: [AsrModel]
        // languages lives on AsrModel, not on AsrProgram
        let asrModel = WyomingValue.object([
            "name": .string("parakeet-tdt-0.6b"),
            "description": .string("Parakeet TDT 0.6B on-device ASR via FluidAudio"),
            "attribution": asrAttribution,
            "installed": .bool(true),
            "version": .string("1.0.0"),
            "languages": .array([.string("en")]),
        ])

        let asrProgram = WyomingValue.object([
            "name": .string("macos-speech-server"),
            "description": .string("macOS on-device speech recognition via FluidAudio"),
            "attribution": asrAttribution,
            "installed": .bool(true),
            "version": .string("1.0.0"),
            "models": .array([asrModel]),
        ])

        // Two-level TTS hierarchy: TtsProgram → voices: [TtsVoice]
        // Build voice list dynamically from the active TTSService.
        let serverAttribution = WyomingValue.object([
            "name": .string("macos-speech-server"),
            "url": .string("https://github.com/dokterbob/macos-speech-server"),
        ])
        let ttsVoices: [WyomingValue] = ttsService.availableVoices.map { name in
            .object([
                "name": .string(name),
                "description": .string(name),
                "attribution": serverAttribution,
                "installed": .bool(true),
                "version": .string("1.0.0"),
                "languages": .array([.string("en")]),
            ])
        }

        let ttsProgram = WyomingValue.object([
            "name": .string("macos-speech-server"),
            "description": .string("macOS on-device TTS"),
            "attribution": serverAttribution,
            "installed": .bool(true),
            "version": .string("1.0.0"),
            "voices": .array(ttsVoices),
            "supports_synthesize_streaming": .bool(true),
        ])

        return WyomingEvent(
            type: "info",
            data: [
                "asr": .array([asrProgram]),
                "tts": .array([ttsProgram]),
                "handle": .array([]),
                "intent": .array([]),
                "wake": .array([]),
                "mic": .array([]),
                "snd": .array([]),
            ]
        )
    }
}
