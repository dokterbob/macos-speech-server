import Vapor

protocol TTSService: Sendable {
    func synthesize(text: String, voice: String) async throws -> Data
}

struct StubTTSService: TTSService {
    func synthesize(text: String, voice: String) async throws -> Data {
        // Minimal silent WAV: 24kHz, 16-bit mono, 0.1s (4800 bytes of silence)
        let sampleRate: UInt32 = 24000
        let bitsPerSample: UInt16 = 16
        let numChannels: UInt16 = 1
        let numSamples: UInt32 = 2400 // 0.1 seconds
        let dataSize = numSamples * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let fileSize = 36 + dataSize

        var wav = Data()
        wav.append(contentsOf: "RIFF".utf8)
        wav.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        wav.append(contentsOf: "WAVE".utf8)
        wav.append(contentsOf: "fmt ".utf8)
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) }) // chunk size
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // PCM
        wav.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian) { Array($0) })
        wav.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        let byteRate = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        wav.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        let blockAlign = numChannels * (bitsPerSample / 8)
        wav.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        wav.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
        wav.append(contentsOf: "data".utf8)
        wav.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        wav.append(Data(count: Int(dataSize))) // silence

        return wav
    }
}

// MARK: - Vapor DI

struct TTSServiceKey: StorageKey {
    typealias Value = any TTSService
}

extension Application {
    var ttsService: any TTSService {
        get { storage[TTSServiceKey.self] ?? StubTTSService() }
        set { storage[TTSServiceKey.self] = newValue }
    }
}

extension Request {
    var ttsService: any TTSService {
        application.ttsService
    }
}
