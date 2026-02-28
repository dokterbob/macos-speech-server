import Foundation

/// Accumulates raw PCM audio chunks and can produce a WAV file.
/// Used for the Wyoming STT flow: accumulate audio-chunk payloads, then write to temp file for STTService.
struct WyomingWAVWriter {
    private var pcmBuffer = Data()
    let sampleRate: Int
    let channels: Int
    let bitsPerSample: Int

    init(sampleRate: Int = 16000, channels: Int = 1, bitsPerSample: Int = 16) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample
    }

    /// Append a PCM chunk to the buffer.
    mutating func append(_ chunk: Data) {
        pcmBuffer.append(chunk)
    }

    /// Total PCM bytes accumulated.
    var byteCount: Int { pcmBuffer.count }

    /// Whether any audio has been accumulated.
    var isEmpty: Bool { pcmBuffer.isEmpty }

    /// Produces a complete WAV file with correct RIFF headers.
    func makeWAV() -> Data {
        let dataSize = pcmBuffer.count
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8

        var wav = Data()

        // RIFF chunk descriptor
        wav.append(contentsOf: "RIFF".utf8)
        wav.appendUInt32LE(UInt32(dataSize + 36))  // total file size - 8
        wav.append(contentsOf: "WAVE".utf8)

        // fmt sub-chunk
        wav.append(contentsOf: "fmt ".utf8)
        wav.appendUInt32LE(16)                          // sub-chunk size
        wav.appendUInt16LE(1)                           // PCM audio format
        wav.appendUInt16LE(UInt16(channels))
        wav.appendUInt32LE(UInt32(sampleRate))
        wav.appendUInt32LE(UInt32(byteRate))
        wav.appendUInt16LE(UInt16(blockAlign))
        wav.appendUInt16LE(UInt16(bitsPerSample))

        // data sub-chunk
        wav.append(contentsOf: "data".utf8)
        wav.appendUInt32LE(UInt32(dataSize))
        wav.append(pcmBuffer)

        return wav
    }

    /// Writes the WAV to a uniquely-named temp file and returns its URL.
    /// Caller is responsible for deleting the file when done.
    func writeToTempFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try makeWAV().write(to: url)
        return url
    }
}

// MARK: - Data helpers

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { self.append(contentsOf: $0) }
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { self.append(contentsOf: $0) }
    }
}
