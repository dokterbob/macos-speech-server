import Foundation

/// A Wyoming protocol event.
struct WyomingEvent: Sendable {
    let type: String
    let version: String
    let data: [String: WyomingValue]
    let payload: Data?

    init(type: String, version: String = "1.0.0", data: [String: WyomingValue] = [:], payload: Data? = nil) {
        self.type = type
        self.version = version
        self.data = data
        self.payload = payload
    }

    /// Serializes the event to wire bytes per the Wyoming protocol.
    func serialize() -> Data {
        var output = Data()

        // Encode data section first to know its byte length
        var dataBytes: Data? = nil
        if !data.isEmpty {
            if let encoded = try? JSONEncoder().encode(data) {
                dataBytes = encoded
            }
        }

        // Build header dict
        var headerDict: [String: Any] = [
            "type": type,
            "version": version,
        ]
        if let db = dataBytes {
            headerDict["data_length"] = db.count
        }
        if let p = payload {
            headerDict["payload_length"] = p.count
        }

        // Serialize header as compact JSON + newline
        if let headerData = try? JSONSerialization.data(withJSONObject: headerDict, options: []) {
            output.append(headerData)
        }
        output.append(0x0A)  // '\n'

        // Append data section
        if let db = dataBytes {
            output.append(db)
        }

        // Append payload
        if let p = payload {
            output.append(p)
        }

        return output
    }
}

/// A value in a Wyoming event data dictionary. Supports nested arrays and objects.
indirect enum WyomingValue: Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([WyomingValue])
    case object([String: WyomingValue])

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var intValue: Int? {
        if case .int(let i) = self { return i }
        return nil
    }

    var doubleValue: Double? {
        if case .double(let d) = self { return d }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var arrayValue: [WyomingValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var objectValue: [String: WyomingValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
}

extension WyomingValue: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .null: try container.encodeNil()
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}

extension WyomingValue: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        }
        else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        }
        else if let i = try? container.decode(Int.self) {
            self = .int(i)
        }
        else if let d = try? container.decode(Double.self) {
            self = .double(d)
        }
        else if let s = try? container.decode(String.self) {
            self = .string(s)
        }
        else if let arr = try? container.decode([WyomingValue].self) {
            self = .array(arr)
        }
        else if let obj = try? container.decode([String: WyomingValue].self) {
            self = .object(obj)
        }
        else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Cannot decode WyomingValue")
            )
        }
    }
}
