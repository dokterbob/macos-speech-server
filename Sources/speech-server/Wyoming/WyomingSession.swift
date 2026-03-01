import Foundation
import Logging

/// Handles a single Wyoming protocol TCP connection, dispatching events to TTS and STT services.
///
/// State machine:
/// ```
/// idle ──synthesize──→ [call TTSService.synthesizeStream, send audio-start/chunk/stop] ──→ idle
/// idle ──transcribe──→ awaitingAudio
/// awaitingAudio ──audio-start──→ recording(WAVWriter)
/// recording ──audio-chunk──→ recording (append PCM)
/// recording ──audio-stop──→ [call STTService.transcribe, send transcript] ──→ idle
/// any state ──describe──→ [send info] (state unchanged)
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
            let text = event.data["text"]?.stringValue ?? ""
            logger.notice("Wyoming: synthesize received, text='\(text.prefix(60))'")
            let voice = resolveVoice(from: event)
            return AsyncStream { continuation in
                Task {
                    await self.streamSynthesize(text: text, voice: voice, continuation: continuation)
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
        } else if case .object(let voiceObj) = event.data["voice"],
                  let voiceName = voiceObj["name"]?.stringValue {
            return voiceName
        }
        return "alba"
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

    private func streamSynthesize(text: String, voice: String, continuation: AsyncStream<Data>.Continuation) async {
        guard !text.isEmpty else {
            logger.warning("synthesize event missing text")
            return
        }

        // PocketTTS outputs 24 kHz, 16-bit mono PCM
        let rate = 24000
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
                            "channels": .int(channels)
                        ]
                    )
                    continuation.yield(audioStart.serialize())
                }
                let audioChunk = WyomingEvent(
                    type: "audio-chunk",
                    data: [
                        "rate": .int(rate),
                        "width": .int(width),
                        "channels": .int(channels)
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
        } catch {
            logger.error("TTS error during synthesize: \(error)")
            // If synthesis failed mid-stream, close the open audio sequence.
            if chunkCount > 0 {
                continuation.yield(WyomingEvent(type: "audio-stop").serialize())
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
        } catch {
            logger.error("STT error during audio-stop: \(error)")
        }
    }

    // MARK: - Info event

    private func makeInfoEvent() -> WyomingEvent {
        let attribution = WyomingValue.object([
            "name": .string("FluidAudio"),
            "url": .string("https://github.com/FluidInference/FluidAudio")
        ])

        // Two-level ASR hierarchy: AsrProgram → models: [AsrModel]
        // languages lives on AsrModel, not on AsrProgram
        let asrModel = WyomingValue.object([
            "name": .string("parakeet-tdt-0.6b"),
            "description": .string("Parakeet TDT 0.6B on-device ASR via FluidAudio"),
            "attribution": attribution,
            "installed": .bool(true),
            "version": .string("1.0.0"),
            "languages": .array([.string("en")])
        ])

        let asrProgram = WyomingValue.object([
            "name": .string("macos-speech-server"),
            "description": .string("macOS on-device speech recognition via FluidAudio"),
            "attribution": attribution,
            "installed": .bool(true),
            "version": .string("1.0.0"),
            "models": .array([asrModel])
        ])

        // Two-level TTS hierarchy: TtsProgram → voices: [TtsVoice]
        // languages lives on TtsVoice, not on TtsProgram
        let ttsVoice = WyomingValue.object([
            "name": .string("alba"),
            "description": .string("Alba voice"),
            "attribution": attribution,
            "installed": .bool(true),
            "version": .string("1.0.0"),
            "languages": .array([.string("en")])
        ])

        let ttsProgram = WyomingValue.object([
            "name": .string("macos-speech-server"),
            "description": .string("macOS on-device TTS via FluidAudio PocketTTS"),
            "attribution": attribution,
            "installed": .bool(true),
            "version": .string("1.0.0"),
            "voices": .array([ttsVoice])
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
                "snd": .array([])
            ]
        )
    }
}
