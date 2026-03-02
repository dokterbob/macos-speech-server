import XCTest

@testable import speech_server

final class WyomingFrameDecoderTests: XCTestCase {
    // Helper: build a wire frame from a WyomingEvent
    private func wire(_ event: WyomingEvent) -> Data { event.serialize() }

    // MARK: - Basic decoding

    func testHeaderOnlyEvent() {
        var decoder = WyomingFrameDecoder()
        let event = WyomingEvent(type: "audio-stop")
        let events = decoder.process(wire(event))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].type, "audio-stop")
        XCTAssertTrue(events[0].data.isEmpty)
        XCTAssertNil(events[0].payload)
    }

    func testEventWithData() {
        var decoder = WyomingFrameDecoder()
        let event = WyomingEvent(type: "transcript", data: ["text": .string("hello")])
        let events = decoder.process(wire(event))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].type, "transcript")
        XCTAssertEqual(events[0].data["text"]?.stringValue, "hello")
        XCTAssertNil(events[0].payload)
    }

    func testEventWithPayload() {
        var decoder = WyomingFrameDecoder()
        let pcm = Data(repeating: 0xAB, count: 128)
        let event = WyomingEvent(
            type: "audio-chunk",
            data: ["rate": .int(16000), "width": .int(2), "channels": .int(1)],
            payload: pcm
        )
        let events = decoder.process(wire(event))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].payload, pcm)
        XCTAssertEqual(events[0].data["rate"]?.intValue, 16000)
    }

    // MARK: - Partial feeds

    func testPartialHeaderFeed() {
        var decoder = WyomingFrameDecoder()
        let event = WyomingEvent(type: "describe")
        let full = wire(event)
        let half = full.count / 2

        let events1 = decoder.process(full[full.startIndex..<full.index(full.startIndex, offsetBy: half)])
        XCTAssertEqual(events1.count, 0)

        let events2 = decoder.process(full[full.index(full.startIndex, offsetBy: half)...])
        XCTAssertEqual(events2.count, 1)
        XCTAssertEqual(events2[0].type, "describe")
    }

    func testPartialDataSectionFeed() {
        var decoder = WyomingFrameDecoder()
        let event = WyomingEvent(type: "transcript", data: ["text": .string("hello world this is a test")])
        let full = wire(event)

        // Feed byte by byte
        var allEvents: [WyomingEvent] = []
        for i in 0..<full.count {
            let byte = full[full.index(full.startIndex, offsetBy: i)..<full.index(full.startIndex, offsetBy: i + 1)]
            allEvents.append(contentsOf: decoder.process(byte))
        }
        XCTAssertEqual(allEvents.count, 1)
        XCTAssertEqual(allEvents[0].data["text"]?.stringValue, "hello world this is a test")
    }

    func testPartialPayloadFeed() {
        var decoder = WyomingFrameDecoder()
        let pcm = Data(repeating: 0x42, count: 256)
        let event = WyomingEvent(
            type: "audio-chunk",
            data: ["rate": .int(16000), "width": .int(2), "channels": .int(1)],
            payload: pcm
        )
        let full = wire(event)

        // Feed everything except last byte
        let events1 = decoder.process(full[full.startIndex..<full.index(before: full.endIndex)])
        XCTAssertEqual(events1.count, 0)

        // Feed the last byte
        let events2 = decoder.process(full[full.index(before: full.endIndex)...])
        XCTAssertEqual(events2.count, 1)
        XCTAssertEqual(events2[0].payload, pcm)
    }

    // MARK: - Multiple events

    func testMultipleEventsInOneCall() {
        var decoder = WyomingFrameDecoder()
        let e1 = WyomingEvent(type: "audio-stop")
        let e2 = WyomingEvent(type: "transcript", data: ["text": .string("hi")])
        let e3 = WyomingEvent(type: "describe")

        var combined = wire(e1)
        combined.append(wire(e2))
        combined.append(wire(e3))

        let events = decoder.process(combined)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0].type, "audio-stop")
        XCTAssertEqual(events[1].type, "transcript")
        XCTAssertEqual(events[2].type, "describe")
    }

    func testMultipleEventsPartialFeed() {
        var decoder = WyomingFrameDecoder()
        let e1 = WyomingEvent(type: "audio-stop")
        let e2 = WyomingEvent(type: "describe")

        var combined = wire(e1)
        combined.append(wire(e2))

        // Feed first half
        let mid = combined.count / 2
        let events1 = decoder.process(
            combined[combined.startIndex..<combined.index(combined.startIndex, offsetBy: mid)])

        // Feed second half
        let events2 = decoder.process(combined[combined.index(combined.startIndex, offsetBy: mid)...])

        let all = events1 + events2
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[0].type, "audio-stop")
        XCTAssertEqual(all[1].type, "describe")
    }

    // MARK: - Reset

    func testResetDiscardsState() {
        var decoder = WyomingFrameDecoder()
        let event = WyomingEvent(type: "describe")
        let full = wire(event)

        // Feed partial
        _ = decoder.process(full[full.startIndex..<full.index(full.startIndex, offsetBy: 5)])

        // Reset
        decoder.reset()

        // Feed a complete event — should work fresh
        let newEvent = WyomingEvent(type: "audio-stop")
        let events = decoder.process(wire(newEvent))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].type, "audio-stop")
    }

    // MARK: - Round-trip

    func testRoundTripWithComplexData() {
        var decoder = WyomingFrameDecoder()
        let event = WyomingEvent(
            type: "audio-chunk",
            data: ["rate": .int(24000), "width": .int(2), "channels": .int(1)],
            payload: Data([0x01, 0x02, 0x03])
        )
        let decoded = decoder.process(wire(event))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].type, "audio-chunk")
        XCTAssertEqual(decoded[0].data["rate"]?.intValue, 24000)
        XCTAssertEqual(decoded[0].payload, Data([0x01, 0x02, 0x03]))
    }
}
