import XCTest
@testable import speech_server

final class WyomingEventTests: XCTestCase {

    // MARK: - WyomingValue conversions

    func testStringValue() {
        let v = WyomingValue.string("hello")
        XCTAssertEqual(v.stringValue, "hello")
        XCTAssertNil(v.intValue)
        XCTAssertNil(v.boolValue)
    }

    func testIntValue() {
        let v = WyomingValue.int(42)
        XCTAssertEqual(v.intValue, 42)
        XCTAssertNil(v.stringValue)
    }

    func testDoubleValue() {
        let v = WyomingValue.double(3.14)
        XCTAssertEqual(v.doubleValue ?? 0, 3.14, accuracy: 0.001)
        XCTAssertNil(v.intValue)
    }

    func testBoolValue() {
        let v = WyomingValue.bool(true)
        XCTAssertEqual(v.boolValue, true)
        XCTAssertNil(v.stringValue)
    }

    func testNullValue() {
        let v = WyomingValue.null
        XCTAssertNil(v.stringValue)
        XCTAssertNil(v.intValue)
        XCTAssertNil(v.boolValue)
    }

    func testArrayValue() {
        let v = WyomingValue.array([.string("a"), .int(1)])
        XCTAssertEqual(v.arrayValue?.count, 2)
        XCTAssertNil(v.stringValue)
    }

    func testObjectValue() {
        let v = WyomingValue.object(["key": .string("val")])
        XCTAssertEqual(v.objectValue?["key"]?.stringValue, "val")
        XCTAssertNil(v.stringValue)
    }

    // MARK: - WyomingValue Codable

    func testWyomingValueEncodeString() throws {
        let v = WyomingValue.string("hello")
        let data = try JSONEncoder().encode(v)
        let str = String(data: data, encoding: .utf8)
        XCTAssertEqual(str, "\"hello\"")
    }

    func testWyomingValueEncodeInt() throws {
        let v = WyomingValue.int(42)
        let data = try JSONEncoder().encode(v)
        let str = String(data: data, encoding: .utf8)
        XCTAssertEqual(str, "42")
    }

    func testWyomingValueEncodeBool() throws {
        let v = WyomingValue.bool(true)
        let data = try JSONEncoder().encode(v)
        let str = String(data: data, encoding: .utf8)
        XCTAssertEqual(str, "true")
    }

    func testWyomingValueDecodeFromJSON() throws {
        let json = """
        {"text":"hello","rate":16000,"active":true}
        """.data(using: .utf8)!
        let dict = try JSONDecoder().decode([String: WyomingValue].self, from: json)
        XCTAssertEqual(dict["text"]?.stringValue, "hello")
        XCTAssertEqual(dict["rate"]?.intValue, 16000)
        XCTAssertEqual(dict["active"]?.boolValue, true)
    }

    func testWyomingValueDecodeNestedArray() throws {
        let json = """
        {"items":["a","b"]}
        """.data(using: .utf8)!
        let dict = try JSONDecoder().decode([String: WyomingValue].self, from: json)
        let items = dict["items"]?.arrayValue
        XCTAssertEqual(items?.count, 2)
        XCTAssertEqual(items?[0].stringValue, "a")
    }

    func testWyomingValueDecodeNestedObject() throws {
        let json = """
        {"voice":{"name":"alba","language":"en"}}
        """.data(using: .utf8)!
        let dict = try JSONDecoder().decode([String: WyomingValue].self, from: json)
        let voice = dict["voice"]?.objectValue
        XCTAssertEqual(voice?["name"]?.stringValue, "alba")
        XCTAssertEqual(voice?["language"]?.stringValue, "en")
    }

    // MARK: - WyomingEvent serialize

    func testSerializeHeaderOnly() {
        let event = WyomingEvent(type: "audio-stop")
        let data = event.serialize()
        let str = String(data: data, encoding: .utf8)!
        // Should end with \n and contain type + version
        XCTAssertTrue(str.hasSuffix("\n"))
        XCTAssertTrue(str.contains("\"type\""))
        XCTAssertTrue(str.contains("audio-stop"))
        XCTAssertTrue(str.contains("1.0.0"))
        // Should NOT contain data_length or payload_length
        XCTAssertFalse(str.contains("data_length"))
        XCTAssertFalse(str.contains("payload_length"))
    }

    func testSerializeWithData() throws {
        let event = WyomingEvent(type: "transcript", data: ["text": .string("hello world")])
        let bytes = event.serialize()

        // Find the newline that ends the header
        let newlineIdx = bytes.firstIndex(of: 0x0A)!
        let headerData = bytes[bytes.startIndex..<newlineIdx]
        let headerJSON = try JSONSerialization.jsonObject(with: headerData) as! [String: Any]

        XCTAssertEqual(headerJSON["type"] as? String, "transcript")
        XCTAssertEqual(headerJSON["version"] as? String, "1.0.0")
        let dataLength = headerJSON["data_length"] as? Int
        XCTAssertNotNil(dataLength)
        XCTAssertGreaterThan(dataLength!, 0)
        XCTAssertNil(headerJSON["payload_length"])

        // Parse data section
        let afterNewline = bytes.index(after: newlineIdx)
        let dataSection = bytes[afterNewline...]
        XCTAssertEqual(dataSection.count, dataLength!)
        let dataDict = try JSONDecoder().decode([String: WyomingValue].self, from: Data(dataSection))
        XCTAssertEqual(dataDict["text"]?.stringValue, "hello world")
    }

    func testSerializeWithPayload() throws {
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        let event = WyomingEvent(
            type: "audio-chunk",
            data: ["rate": .int(16000), "width": .int(2), "channels": .int(1)],
            payload: pcm
        )
        let bytes = event.serialize()

        let newlineIdx = bytes.firstIndex(of: 0x0A)!
        let headerData = bytes[bytes.startIndex..<newlineIdx]
        let headerJSON = try JSONSerialization.jsonObject(with: headerData) as! [String: Any]

        let dataLength = headerJSON["data_length"] as! Int
        let payloadLength = headerJSON["payload_length"] as! Int
        XCTAssertEqual(payloadLength, 4)

        // Verify payload bytes at end
        let payloadStart = bytes.index(bytes.index(after: newlineIdx), offsetBy: dataLength)
        let payloadSection = bytes[payloadStart...]
        XCTAssertEqual(Data(payloadSection), pcm)
    }

    func testSerializeHeaderOnlyHasNoDataOrPayloadLength() {
        let event = WyomingEvent(type: "describe")
        let bytes = event.serialize()
        let newlineIdx = bytes.firstIndex(of: 0x0A)!
        let headerData = Data(bytes[bytes.startIndex..<newlineIdx])
        let headerJSON = try! JSONSerialization.jsonObject(with: headerData) as! [String: Any]
        XCTAssertNil(headerJSON["data_length"])
        XCTAssertNil(headerJSON["payload_length"])
    }
}
