import Foundation
import Logging
import NIOCore

/// NIO `ChannelInboundHandler` that bridges the Wyoming framing layer to `WyomingSession`.
///
/// Bytes arriving on the channel are fed into `WyomingFrameDecoder`; decoded `WyomingEvent`s
/// are enqueued into a single `AsyncStream`. A serial processing Task dequeues events one at
/// a time, calling `session.handle(event:)` and draining the resulting response stream to
/// completion before moving on to the next event.
///
/// The serial ordering guarantee is critical for streaming TTS: it ensures that all audio
/// chunks from each `synthesize-chunk` are written to the channel before `synthesize-stop`
/// is processed, so `synthesize-stopped` is only sent after all audio has been delivered.
///
/// `frameDecoder` and `eventContinuation` are only ever accessed on the channel's event loop
/// thread (`channelActive`, `channelRead`, `errorCaught`, `channelInactive`) — hence
/// `@unchecked Sendable` is sound.
final class WyomingChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn  = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var frameDecoder = WyomingFrameDecoder()
    private let session: WyomingSession
    private let logger: Logger
    private var eventContinuation: AsyncStream<WyomingEvent>.Continuation?

    init(session: WyomingSession, logger: Logger) {
        self.session = session
        self.logger = logger
    }

    func channelActive(context: ChannelHandlerContext) {
        logger.notice("Wyoming connection opened from \(context.remoteAddress?.description ?? "unknown")")

        // Create the serial event queue. The continuation is stored so channelRead can feed it.
        let (eventStream, continuation) = AsyncStream<WyomingEvent>.makeStream()
        self.eventContinuation = continuation

        // `Channel` conforms to `Sendable` in NIO 2.62+, safe to capture across task boundary.
        let channel = context.channel
        let session = self.session
        let log = self.logger

        // Single consumer Task: processes events strictly in arrival order.
        // Each event's response stream is fully drained before the next event is dequeued,
        // ensuring audio is sent before synthesize-stopped.
        Task {
            for await event in eventStream {
                log.notice("Wyoming event received: \(event.type)")
                for await responseData in await session.handle(event: event) {
                    var outBuf = channel.allocator.buffer(capacity: responseData.count)
                    outBuf.writeBytes(responseData)
                    channel.writeAndFlush(outBuf, promise: nil)
                }
            }
        }

        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        let byteCount = buffer.readableBytes
        guard byteCount > 0, let bytes = buffer.readBytes(length: byteCount) else { return }

        logger.debug("Wyoming received \(byteCount) bytes")
        let events = frameDecoder.process(Data(bytes))
        for event in events {
            eventContinuation?.yield(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.warning("Wyoming connection error: \(error)")
        eventContinuation?.finish()
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        logger.notice("Wyoming connection closed")
        eventContinuation?.finish()
        context.fireChannelInactive()
    }
}
