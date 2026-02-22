import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import WorkforceKit

enum SocketClient {
    static let socketPath = "/tmp/workforce-\(getuid()).sock"

    /// Send a message to the Workforce app. Returns silently if the app isn't running.
    static func send(_ message: SocketMessage) {
        do {
            let data = try JSONEncoder().encode(message)
            var payload = [UInt8](data)
            payload.append(0x0A) // newline delimiter

            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else {
                fputs("[workforce] socket() failed: \(errno)\n", stderr)
                return
            }
            defer { close(fd) }

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = socketPath.utf8CString
            guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
                fputs("[workforce] socket path too long\n", stderr)
                return
            }
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                    pathBytes.withUnsafeBufferPointer { src in
                        _ = memcpy(dest, src.baseAddress!, src.count)
                    }
                }
            }

            let connectResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connectResult == 0 else {
                fputs("[workforce] connect() failed: \(errno) (\(String(cString: strerror(errno))))\n", stderr)
                return
            }

            payload.withUnsafeBytes { buf in
                var sent = 0
                while sent < buf.count {
                    let n = Darwin.write(fd, buf.baseAddress! + sent, buf.count - sent)
                    guard n > 0 else {
                        fputs("[workforce] write() failed at offset \(sent): \(errno)\n", stderr)
                        return
                    }
                    sent += n
                }
            }

            // Graceful shutdown: send FIN so the NWConnection server sees
            // isComplete=true and processes the buffered data before we close.
            Darwin.shutdown(fd, SHUT_WR)

            // Wait for the server to close its end (read returns 0).
            var drain = [UInt8](repeating: 0, count: 1)
            _ = Darwin.read(fd, &drain, 1)
        } catch {
            fputs("[workforce] encode error: \(error)\n", stderr)
        }
    }
}
