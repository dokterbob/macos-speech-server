import Foundation
import NIOCore
import NIOPosix
import Vapor

/// Binds a Wyoming protocol TCP server and registers it with Vapor's lifecycle.
///
/// One `WyomingSession` is created per accepted connection. The server shares
/// `app.eventLoopGroup` with Vapor — no extra threads are created.
///
/// `@unchecked Sendable`: `serverChannel` is written once in `didBoot` and read
/// once in `shutdown`; lifecycle guarantees these are called sequentially.
final class WyomingServer: LifecycleHandler, @unchecked Sendable {
    private let host: String
    private let port: Int
    private let ttsService: any TTSService
    private let sttService: any STTService
    private let sttInfo: STTInfo
    private let logger: Logger
    private var serverChannel: (any Channel)?

    init(
        host: String,
        port: Int,
        ttsService: any TTSService,
        sttService: any STTService,
        sttInfo: STTInfo = .parakeet(),
        logger: Logger
    ) {
        self.host = host
        self.port = port
        self.ttsService = ttsService
        self.sttService = sttService
        self.sttInfo = sttInfo
        self.logger = logger
    }

    /// The server bootstrap: one `WyomingSession` + `WyomingChannelHandler` per accepted connection.
    /// Shared with the tests so they exercise the production channel options.
    static func makeBootstrap(
        group: any EventLoopGroup,
        ttsService: any TTSService,
        sttService: any STTService,
        sttInfo: STTInfo,
        logger: Logger
    ) -> ServerBootstrap {
        ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let session = WyomingSession(
                    ttsService: ttsService, sttService: sttService, sttInfo: sttInfo, logger: logger)
                let handler = WyomingChannelHandler(session: session, logger: logger)
                return channel.pipeline.addHandler(handler)
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
    }

    func didBoot(_ application: Application) throws {
        let bootstrap = Self.makeBootstrap(
            group: application.eventLoopGroup,
            ttsService: ttsService,
            sttService: sttService,
            sttInfo: sttInfo,
            logger: logger
        )
        let channel = try bootstrap.bind(host: host, port: port).wait()
        serverChannel = channel
        logger.notice("Wyoming server listening on \(host):\(port)")
    }

    func shutdown(_ application: Application) {
        serverChannel?.close(promise: nil)
        logger.notice("Wyoming server stopping.")
    }
}
