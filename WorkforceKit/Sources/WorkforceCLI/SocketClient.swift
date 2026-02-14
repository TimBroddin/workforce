import Foundation
import NIOCore
import NIOPosix
import WorkforceKit

enum SocketClient {
    static let socketPath = "/tmp/workforce-\(getuid()).sock"

    /// Send a message to the Workforce app. Returns silently if the app isn't running.
    static func send(_ message: SocketMessage) {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        do {
            let data = try JSONEncoder().encode(message)
            let payload = data + Data([0x0A]) // newline delimiter

            let bootstrap = ClientBootstrap(group: group)
                .channelOption(.socketOption(.so_reuseaddr), value: 1)
                .connectTimeout(.milliseconds(100))
                .channelInitializer { channel in
                    channel.eventLoop.makeSucceededVoidFuture()
                }

            let channel = try bootstrap
                .connect(unixDomainSocketPath: socketPath)
                .wait()

            var buffer = channel.allocator.buffer(capacity: payload.count)
            buffer.writeBytes(payload)
            try channel.writeAndFlush(buffer).wait()
            try channel.close().wait()
        } catch {
            // App not running or socket unavailable -- exit silently
        }
    }
}
