import FluidAudio
import Foundation
import Logging

final class KokoroTTSService: TTSService, @unchecked Sendable {
    let sampleRate: Int = KokoroAneConstants.sampleRate
    private(set) var defaultVoice: String = KokoroAneConstants.defaultVoice
    let availableVoices: [String] = KokoroAneConstants.englishVoices.sorted()

    private var manager: KokoroAneManager?
    private let misaki = MisakiPhonemizer()
    private var logger: Logger = {
        var l = Logger(label: "KokoroTTSService")
        l.logLevel = .notice
        return l
    }()

    func initialize(settings: KokoroSettings = KokoroSettings()) async throws {
        let voiceId = settings.defaultVoice ?? KokoroAneConstants.defaultVoice
        guard availableVoices.contains(voiceId) else {
            throw KokoroTTSError.voiceNotFound(voiceId)
        }
        let m = KokoroAneManager(defaultVoice: voiceId)
        try await m.initialize()
        self.manager = m
        self.defaultVoice = voiceId
        if misaki.isAvailable {
            do {
                try await misaki.warmUp()
            }
            catch {
                logger.warning("Misaki warmUp failed, will fall back to FluidAudio G2P: \(error)")
            }
        }
    }

    private func isBritishVoice(_ voice: String) -> Bool {
        voice.hasPrefix("bf_") || voice.hasPrefix("bm_")
    }

    private func synthesizeSentence(
        _ sentence: String,
        voice: String,
        british: Bool,
        manager: KokoroAneManager
    ) async throws -> KokoroAneSynthesisResult {
        if misaki.isAvailable {
            do {
                let phonemes = try await misaki.phonemize(sentence, british: british)
                if !phonemes.isEmpty {
                    return try await manager.synthesizeFromPhonemesDetailed(
                        phonemes, voice: voice)
                }
            }
            catch {
                logger.warning(
                    "Misaki G2P/synthesis failed, falling back to FluidAudio G2P: \(error)")
            }
        }
        return try await manager.synthesizeDetailed(text: sentence, voice: voice)
    }

    // Returns a complete WAV file produced via KokoroAneManager.
    func synthesize(text: String, voice: String) async throws -> Data {
        guard let manager = manager else {
            throw KokoroTTSError.notInitialized
        }
        guard availableVoices.contains(voice) else {
            throw KokoroTTSError.voiceNotFound(voice)
        }
        logger.notice("Kokoro synthesize: \(text.prefix(80))...")
        let sentences = detectSentences(text)
        let british = isBritishVoice(voice)
        var pcm = Data()
        for sentence in sentences {
            let result = try await synthesizeSentence(
                sentence, voice: voice, british: british, manager: manager)
            if !result.samples.isEmpty {
                pcm.append(float32ToPCM16(result.samples))
            }
        }
        if !pcm.isEmpty {
            let wav = makeWavData(pcm16: pcm, sampleRate: sampleRate)
            logger.notice("Kokoro synthesis done: \(wav.count) bytes")
            return wav
        }
        let data = try await manager.synthesize(text: text, voice: voice)
        logger.notice("Kokoro synthesis done: \(data.count) bytes")
        return data
    }

    private func makeWavData(pcm16: Data, sampleRate: Int) -> Data {
        var header = Data(capacity: 44 + pcm16.count)
        let dataSize = UInt32(pcm16.count)
        let chunkSize = UInt32(36) + dataSize
        let rate = UInt32(sampleRate)
        let byteRate = rate * 2
        header.append(contentsOf: "RIFF".utf8)
        withUnsafeBytes(of: chunkSize.littleEndian) { header.append(contentsOf: $0) }
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        withUnsafeBytes(of: UInt32(16).littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(1).littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(1).littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: rate.littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: byteRate.littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(2).littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(16).littleEndian) { header.append(contentsOf: $0) }
        header.append(contentsOf: "data".utf8)
        withUnsafeBytes(of: dataSize.littleEndian) { header.append(contentsOf: $0) }
        header.append(pcm16)
        return header
    }

    // Yields raw 16-bit little-endian PCM (24 kHz mono, no WAV header) one chunk per
    // sentence. All Float32 samples for a sentence are collected from KokoroSynthesizer
    // chunk results, peak-normalised once, and converted to PCM16.
    func synthesizeStream(text: String, voice: String) -> AsyncThrowingStream<Data, Error> {
        guard availableVoices.contains(voice) else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: KokoroTTSError.voiceNotFound(voice))
            }
        }

        let sentences = detectSentences(text)
        let british = isBritishVoice(voice)
        logger.notice("Kokoro synthesizeStream: \(sentences.count) sentence(s)")

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let manager = self.manager else {
                        throw KokoroTTSError.notInitialized
                    }
                    for sentence in sentences {
                        let result = try await self.synthesizeSentence(
                            sentence, voice: voice, british: british, manager: manager)
                        if !result.samples.isEmpty {
                            continuation.yield(float32ToPCM16(result.samples))
                        }
                    }
                    continuation.finish()
                }
                catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

// MARK: - Errors

enum KokoroTTSError: Error, CustomStringConvertible {
    case notInitialized
    case voiceNotFound(String)

    var description: String {
        switch self {
        case .notInitialized:
            return "Kokoro TTS service has not been initialized."
        case .voiceNotFound(let voice):
            return "Voice '\(voice)' is not available. Use a Kokoro voice ID (e.g. 'af_heart', 'am_adam')."
        }
    }
}
