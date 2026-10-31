import Darwin
import Foundation

/// Length-prefixed JSON, maximum 2 MB, one request/response per connection.
/// Kept independent of Vapor so the UI and management commands never load speech dependencies.
public enum LocalSocket {
    public static let maximumMessageSize = 2 * 1024 * 1024

    private static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw ManagementError("Management socket path is too long.")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    private static func configure(_ descriptor: Int32) {
        var timeout = timeval(tv_sec: 20, tv_usec: 0)
        var yes: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    }

    private static func systemError(_ operation: String) -> ManagementError {
        ManagementError("\(operation): \(String(cString: strerror(errno)))")
    }

    public static func request(
        _ request: ManagementRequest, path: String = AppPaths().socket
    ) throws -> ManagementResponse {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw systemError("Create socket") }
        defer { close(descriptor) }
        configure(descriptor)
        var address = try address(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            throw ManagementError(
                "The app background service is unavailable. Open Speech Server and enable its background service.")
        }
        try checkPeer(descriptor)
        try send(JSONEncoder().encode(request), to: descriptor)
        return try JSONDecoder().decode(ManagementResponse.self, from: receive(from: descriptor)).checked()
    }

    public static func listen(path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw systemError("Create socket") }
        configure(descriptor)
        do {
            var address = try address(path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw systemError("Bind management socket") }
            guard chmod(path, 0o600) == 0, Darwin.listen(descriptor, 8) == 0 else { throw systemError("Listen") }
            return descriptor
        }
        catch {
            close(descriptor)
            throw error
        }
    }

    public static func serve(descriptor: Int32, handler: (ManagementRequest) -> ManagementResponse) throws {
        let client = accept(descriptor, nil, nil)
        guard client >= 0 else {
            if errno == EINTR { return }
            throw systemError("Accept")
        }
        defer { close(client) }
        configure(client)
        do {
            try checkPeer(client)
            let request = try JSONDecoder().decode(ManagementRequest.self, from: receive(from: client))
            let response =
                request.version == 1
                ? handler(request) : ManagementResponse(error: "Unsupported management protocol version.")
            try send(JSONEncoder().encode(response), to: client)
        }
        catch { try? send(JSONEncoder().encode(ManagementResponse(error: error.localizedDescription)), to: client) }
    }

    private static func checkPeer(_ descriptor: Int32) throws {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(descriptor, &uid, &gid) == 0, uid == getuid() else {
            throw ManagementError("Management connections must belong to the current user.")
        }
    }

    private static func receive(from descriptor: Int32) throws -> Data {
        let header = try readExactly(4, descriptor: descriptor)
        let count = header.reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= maximumMessageSize else { throw ManagementError("Invalid management message size.") }
        return try readExactly(count, descriptor: descriptor)
    }

    private static func readExactly(_ count: Int, descriptor: Int32) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let received = Darwin.read(descriptor, bytes.baseAddress!.advanced(by: offset), count - offset)
                if received < 0 && errno == EINTR { continue }
                guard received > 0 else { throw ManagementError("Management connection closed or timed out.") }
                offset += received
            }
        }
        return data
    }

    private static func send(_ data: Data, to descriptor: Int32) throws {
        guard data.count <= maximumMessageSize else { throw ManagementError("Management response is too large.") }
        var length = UInt32(data.count).bigEndian
        var framed = withUnsafeBytes(of: &length) { Data($0) }
        framed.append(data)
        try framed.withUnsafeBytes { bytes in
            var offset = 0
            while offset < framed.count {
                let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), framed.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw systemError("Write management message") }
                offset += written
            }
        }
    }
}
