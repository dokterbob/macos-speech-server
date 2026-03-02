import Foundation

/// Pure Swift state machine for decoding Wyoming protocol frames from a byte stream.
/// No NIO dependencies — can be unit tested with plain `Data` inputs.
struct WyomingFrameDecoder {
    private var buffer = Data()
    private var state: State = .readingHeader

    private enum State {
        case readingHeader
        case readingData(type: String, version: String, dataLength: Int, payloadLength: Int)
        case readingPayload(type: String, version: String, data: [String: WyomingValue], payloadLength: Int)
    }

    /// Feed bytes into the decoder. Returns all complete events that can be extracted.
    mutating func process(_ bytes: Data) -> [WyomingEvent] {
        buffer.append(bytes)
        var results: [WyomingEvent] = []

        outer: while true {
            switch state {
            case .readingHeader:
                guard let newlineOffset = buffer.firstIndex(of: 0x0A) else {
                    break outer
                }
                let headerData = buffer[buffer.startIndex..<newlineOffset]
                // Advance buffer past the newline
                let afterNewline = buffer.index(after: newlineOffset)
                buffer = afterNewline < buffer.endIndex ? Data(buffer[afterNewline...]) : Data()

                guard let header = parseHeader(Data(headerData)) else {
                    // Invalid header — reset and stop
                    state = .readingHeader
                    break outer
                }

                let dataLen = header.dataLength
                let payloadLen = header.payloadLength

                if dataLen == 0 && payloadLen == 0 {
                    // Header-only event
                    results.append(WyomingEvent(type: header.type, version: header.version))
                    // state stays .readingHeader
                }
                else if dataLen > 0 {
                    state = .readingData(
                        type: header.type,
                        version: header.version,
                        dataLength: dataLen,
                        payloadLength: payloadLen
                    )
                }
                else {
                    // No data but has payload
                    state = .readingPayload(
                        type: header.type,
                        version: header.version,
                        data: [:],
                        payloadLength: payloadLen
                    )
                }

            case .readingData(let type, let version, let dataLength, let payloadLength):
                guard buffer.count >= dataLength else { break outer }
                let dataSection = Data(
                    buffer[buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: dataLength)])
                buffer =
                    buffer.count > dataLength
                    ? Data(buffer[buffer.index(buffer.startIndex, offsetBy: dataLength)...])
                    : Data()

                let dataDict = parseDataDict(dataSection)

                if payloadLength > 0 {
                    state = .readingPayload(type: type, version: version, data: dataDict, payloadLength: payloadLength)
                }
                else {
                    results.append(WyomingEvent(type: type, version: version, data: dataDict))
                    state = .readingHeader
                }

            case .readingPayload(let type, let version, let data, let payloadLength):
                guard buffer.count >= payloadLength else { break outer }
                let payloadData = Data(
                    buffer[buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: payloadLength)])
                buffer =
                    buffer.count > payloadLength
                    ? Data(buffer[buffer.index(buffer.startIndex, offsetBy: payloadLength)...])
                    : Data()

                results.append(WyomingEvent(type: type, version: version, data: data, payload: payloadData))
                state = .readingHeader
            }
        }

        return results
    }

    /// Resets the decoder to its initial state, discarding buffered bytes.
    mutating func reset() {
        buffer = Data()
        state = .readingHeader
    }

    // MARK: - Private helpers

    private struct ParsedHeader {
        let type: String
        let version: String
        let dataLength: Int
        let payloadLength: Int
    }

    private func parseHeader(_ data: Data) -> ParsedHeader? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = json["type"] as? String,
            let version = json["version"] as? String
        else { return nil }

        let dataLength = json["data_length"] as? Int ?? 0
        let payloadLength = json["payload_length"] as? Int ?? 0
        return ParsedHeader(type: type, version: version, dataLength: dataLength, payloadLength: payloadLength)
    }

    private func parseDataDict(_ data: Data) -> [String: WyomingValue] {
        guard let decoded = try? JSONDecoder().decode([String: WyomingValue].self, from: data) else {
            return [:]
        }
        return decoded
    }
}
