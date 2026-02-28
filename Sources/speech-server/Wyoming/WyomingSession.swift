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

    /// Handle an incoming Wyoming event. Returns serialized wire bytes for all response events.
    func handle(event: WyomingEvent) async -> [Data] {
        switch event.type {
        case "describe":
            logger.notice("Wyoming: describe received, sending info")
            return [makeInfoEvent().serialize()]

        case "synthesize":
            let text = event.data["text"]?.stringValue ?? ""
            logger.notice("Wyoming: synthesize received, text='\(text.prefix(60))'")
            return await handleSynthesize(event: event)

        case "transcribe":
            logger.notice("Wyoming: transcribe received, awaiting audio")
            state = .awaitingAudio
            return []

        case "audio-start":
            logger.notice("Wyoming: audio-start received")
            return handleAudioStart(event: event)

        case "audio-chunk":
            return handleAudioChunk(event: event)

        case "audio-stop":
            logger.notice("Wyoming: audio-stop received, transcribing")
            return await handleAudioStop()

        default:
            logger.warning("Unknown Wyoming event type: \(event.type)")
            return []
        }
    }

    // MARK: - Event handlers

    private func handleSynthesize(event: WyomingEvent) async -> [Data] {
        guard let text = event.data["text"]?.stringValue, !text.isEmpty else {
            logger.warning("synthesize event missing text")
            return []
        }

        // Voice can be a string or an object with a "name" field; default to "alba"
        let voice: String
        if let voiceStr = event.data["voice"]?.stringValue {
            voice = voiceStr
        } else if case .object(let voiceObj) = event.data["voice"],
                  let voiceName = voiceObj["name"]?.stringValue {
            voice = voiceName
        } else {
            voice = "alba"
        }

        do {
            var pcmChunks: [Data] = []
            for try await chunk in ttsService.synthesizeStream(text: text, voice: voice) {
                pcmChunks.append(chunk)
            }

            // PocketTTS outputs 24 kHz, 16-bit mono PCM
            let rate = 24000
            let width = 2
            let channels = 1

            var responses: [Data] = []

            // audio-start
            let audioStart = WyomingEvent(
                type: "audio-start",
                data: [
                    "rate": .int(rate),
                    "width": .int(width),
                    "channels": .int(channels)
                ]
            )
            responses.append(audioStart.serialize())

            // audio-chunk for each PCM chunk
            for chunk in pcmChunks {
                let audioChunk = WyomingEvent(
                    type: "audio-chunk",
                    data: [
                        "rate": .int(rate),
                        "width": .int(width),
                        "channels": .int(channels)
                    ],
                    payload: chunk
                )
                responses.append(audioChunk.serialize())
            }

            // audio-stop
            responses.append(WyomingEvent(type: "audio-stop").serialize())

            logger.notice("Wyoming: synthesize complete, \(pcmChunks.count) chunk(s)")
            return responses
        } catch {
            logger.error("TTS error during synthesize: \(error)")
            return []
        }
    }

    private func handleAudioStart(event: WyomingEvent) -> [Data] {
        guard case .awaitingAudio = state else {
            logger.warning("audio-start received in unexpected state, ignoring")
            return []
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
        return []
    }

    private func handleAudioChunk(event: WyomingEvent) -> [Data] {
        guard case .recording(var writer, let rate, let width, let channels) = state else {
            return []
        }
        if let pcm = event.payload {
            writer.append(pcm)
        }
        state = .recording(writer: writer, rate: rate, width: width, channels: channels)
        return []
    }

    private func handleAudioStop() async -> [Data] {
        guard case .recording(let writer, _, _, _) = state else {
            state = .idle
            return []
        }
        state = .idle

        do {
            let audioURL = try writer.writeToTempFile()
            defer { try? FileManager.default.removeItem(at: audioURL) }

            let result = try await sttService.transcribe(audioURL: audioURL)
            logger.notice("Wyoming: transcription result='\(result.text)'")
            let transcript = WyomingEvent(
                type: "transcript",
                data: ["text": .string(result.text)]
            )
            return [transcript.serialize()]
        } catch {
            logger.error("STT error during audio-stop: \(error)")
            return []
        }
    }

    // MARK: - Info event

    private func makeInfoEvent() -> WyomingEvent {
        let attribution = WyomingValue.object([
            "name": .string("FluidAudio"),
            "url": .string("https://github.com/FluidInference/FluidAudio")
        ])

        let asrModel = WyomingValue.object([
            "name": .string("macos-speech-server"),
            "description": .string("macOS on-device speech recognition via FluidAudio"),
            "attribution": attribution,
            "installed": .bool(true),
            "languages": .array([.string("en")]),
            "version": .string("1.0.0")
        ])

        let ttsVoice = WyomingValue.object([
            "name": .string("alba"),
            "description": .string("Alba voice"),
            "attribution": attribution,
            "installed": .bool(true),
            "languages": .array([.string("en")])
        ])

        let ttsProgram = WyomingValue.object([
            "name": .string("macos-speech-server"),
            "description": .string("macOS on-device TTS via FluidAudio PocketTTS"),
            "attribution": attribution,
            "installed": .bool(true),
            "voices": .array([ttsVoice]),
            "version": .string("1.0.0")
        ])

        return WyomingEvent(
            type: "info",
            data: [
                "asr": .array([asrModel]),
                "tts": .array([ttsProgram])
            ]
        )
    }
}
