import Logging
import NIOCore
import NIOPosix
import XCTest

@testable import speech_server

/// Connection lifecycle over a real TCP socket, using the production bootstrap
/// (`WyomingServer.makeBootstrap`) bound to an ephemeral port with mock services.
final class WyomingServerTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!

    override func setUp() {
        super.setUp()
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    override func tearDown() {
        try? group.syncShutdownGracefully()
        group = nil
        super.tearDown()
    }

    // Regression: the server enables `allowRemoteHalfClosure`, so a client closing its side arrives as
    // `ChannelEvent.inputClosed` rather than closing the channel. The handler ignored that event, so the
    // server never closed its end: every connection leaked a socket until the process ran out of file
    // descriptors and all new connections were reset.
    func testServerAnswersThenClosesAfterClientHalfCloses() async throws {
        let server = try await WyomingServer.makeBootstrap(
            group: group,
            ttsService: MockTTSService(),
            sttService: MockSTTService(),
            sttInfo: .parakeet(),
            logger: Logger(label: "wyoming-server-tests")
        ).bind(host: "127.0.0.1", port: 0).get()
        let port = try XCTUnwrap(server.localAddress?.port)

        let eventLoop = group.next()
        let collector = ResponseCollector(closed: eventLoop.makePromise())
        let client = try await ClientBootstrap(group: eventLoop)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(collector) }
            }
            .connect(host: "127.0.0.1", port: port).get()

        var request = Data(#"{"type":"describe","version":"1.0.0"}"#.utf8)
        request.append(0x0A)
        try await client.writeAndFlush(ByteBuffer(bytes: request)).get()
        try await client.close(mode: .output).get()  // half-close: "done sending"

        // The connection only ends if the server closes its side; give it 5 seconds.
        let timeout = eventLoop.scheduleTask(in: .seconds(5)) {
            collector.closed.fail(ServerDidNotCloseError())
        }
        let received: Data
        do {
            received = try await collector.closed.futureResult.get()
        }
        catch {
            timeout.cancel()
            try? await client.close().get()
            try await server.close().get()
            XCTFail("server did not close the connection after the client half-closed")
            return
        }
        timeout.cancel()

        var decoder = WyomingFrameDecoder()
        XCTAssertEqual(decoder.process(received).map(\.type), ["info"])
        try await server.close().get()
    }
}

private struct ServerDidNotCloseError: Error {}

/// Collects everything the server sends; completes `closed` when the connection ends.
private final class ResponseCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    let closed: EventLoopPromise<Data>
    private var received = Data()

    init(closed: EventLoopPromise<Data>) {
        self.closed = closed
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if let bytes = buffer.readBytes(length: buffer.readableBytes) {
            received.append(contentsOf: bytes)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        closed.succeed(received)
        context.fireChannelInactive()
    }
}
