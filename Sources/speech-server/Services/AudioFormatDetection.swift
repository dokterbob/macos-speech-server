import Foundation
import Logging

private let logger: Logger = {
    var l = Logger(label: "AudioFormatDetection")
    l.logLevel = .notice
    return l
}()

/// Returns the correct file extension (with leading dot) for an audio file.
/// Checks the filename extension first; falls back to magic-byte detection on
/// the first 12 bytes of `header`. Falls back to ".wav" if unrecognised.
func audioFileExtension(filename: String, header: Data) -> String {
    let knownExtensions: Set<String> = ["wav", "mp3", "m4a", "flac", "aiff", "ogg"]
    let ext = (filename as NSString).pathExtension.lowercased()
    if knownExtensions.contains(ext) {
        return ".\(ext)"
    }

    guard header.count >= 12 else { return ".wav" }
    let bytes = Array(header.prefix(12))

    // WAV: "RIFF" at 0, "WAVE" at 8
    if bytes[0...3] == [0x52, 0x49, 0x46, 0x46] && bytes[8...11] == [0x57, 0x41, 0x56, 0x45] {
        return ".wav"
    }
    // FLAC: "fLaC" at 0
    if bytes[0...3] == [0x66, 0x4C, 0x61, 0x43] {
        return ".flac"
    }
    // MP3: "ID3" at 0 or sync bytes 0xFF 0xFB/F3/F2/FA
    if bytes[0...2] == [0x49, 0x44, 0x33] {
        return ".mp3"
    }
    if bytes[0] == 0xFF && [0xFB, 0xF3, 0xF2, 0xFA].contains(bytes[1]) {
        return ".mp3"
    }
    // M4A: "ftyp" at bytes 4–7
    if bytes[4...7] == [0x66, 0x74, 0x79, 0x70] {
        return ".m4a"
    }
    // AIFF: "FORM" at 0, "AIFF"/"AIFC" at 8
    if bytes[0...3] == [0x46, 0x4F, 0x52, 0x4D]
        && (bytes[8...11] == [0x41, 0x49, 0x46, 0x46] || bytes[8...11] == [0x41, 0x49, 0x46, 0x43])
    {
        return ".aiff"
    }

    logger.warning("Could not detect audio format for '\(filename)'; defaulting to .wav")
    return ".wav"
}
