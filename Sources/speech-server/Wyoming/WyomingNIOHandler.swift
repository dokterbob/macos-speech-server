import Foundation
import Logging
import NIOCore

/// NIO `ChannelInboundHandler` that bridges the Wyoming framing layer to `WyomingSession`.
///
/// Bytes arriving on the channel are fed into `WyomingFrameDecoder`; any complete
/// `WyomingEvent`s are dispatched to the session via a Swift `Task`. Response bytes
/// are written to the channel as they arrive from the session's `AsyncStream`.
///
/// `frameDecoder` is only ever accessed from `channelRead`, which NIO guarantees
/// runs on the channel's event loop thread — hence `@unchecked Sendable` is sound.
final class WyomingChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn  = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var frameDecoder = WyomingFrameDecoder()
    private let session: WyomingSession
    private let logger: Logger

    init(session: WyomingSession, logger: Logger) {
        self.session = session
        self.logger = logger
    }

    func channelActive(context: ChannelHandlerContext) {
        logger.notice("Wyoming connection opened from \(context.remoteAddress?.description ?? "unknown")")
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        let byteCount = buffer.readableBytes
        guard byteCount > 0, let bytes = buffer.readBytes(length: byteCount) else { return }

        logger.debug("Wyoming received \(byteCount) bytes")
        let events = frameDecoder.process(Data(bytes))
        guard !events.isEmpty else { return }

        // `Channel` conforms to `Sendable` in NIO 2.62+, safe to capture across task boundary.
        let channel = context.channel
        let session = self.session
        let log = self.logger

        Task {
            for event in events {
                log.notice("Wyoming event received: \(event.type)")
                for await responseData in await session.handle(event: event) {
                    var outBuf = channel.allocator.buffer(capacity: responseData.count)
                    outBuf.writeBytes(responseData)
                    channel.writeAndFlush(outBuf, promise: nil)
                }
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.warning("Wyoming connection error: \(error)")
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        logger.notice("Wyoming connection closed")
        context.fireChannelInactive()
    }
}
