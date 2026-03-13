import Foundation

// MARK: - Shared PCM conversion utilities

// Package-internal. Converts Float32 audio samples to 16-bit little-endian PCM.
// Applies per-batch peak normalisation so the output uses the full 16-bit range.
func float32ToPCM16(_ samples: [Float]) -> Data {
    let maxVal = samples.map({ abs($0) }).max().flatMap({ $0 > 0 ? $0 : nil }) ?? 1.0
    var data = Data(capacity: samples.count * 2)
    for s in samples {
        let v = Int16(max(-32767.0, min(32767.0, (s / maxVal) * 32767.0))).littleEndian
        withUnsafeBytes(of: v) { data.append(contentsOf: $0) }
    }
    return data
}

// Package-internal. Wraps raw 16-bit PCM data in a RIFF/WAVE container with
// correct size fields. Use this for complete (non-streaming) WAV responses.
func makeWAV(pcmData: Data, sampleRate: Int, channels: Int = 1, bitsPerSample: Int = 16) -> Data {
    var wav = Data()
    let dataSize = UInt32(pcmData.count)
    let byteRate = UInt32(sampleRate * channels * bitsPerSample / 8)
    let blockAlign = UInt16(channels * bitsPerSample / 8)

    func u32(_ v: UInt32) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { wav.append(contentsOf: $0) }
    }
    func u16(_ v: UInt16) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { wav.append(contentsOf: $0) }
    }

    wav.append(contentsOf: "RIFF".utf8)
    u32(36 + dataSize)  // file size minus the 8-byte "RIFF" + size field
    wav.append(contentsOf: "WAVE".utf8)
    wav.append(contentsOf: "fmt ".utf8)
    u32(16)  // PCM fmt chunk size
    u16(1)  // PCM audio format
    u16(UInt16(channels))
    u32(UInt32(sampleRate))
    u32(byteRate)
    u16(blockAlign)
    u16(UInt16(bitsPerSample))
    wav.append(contentsOf: "data".utf8)
    u32(dataSize)
    wav.append(pcmData)

    return wav
}
