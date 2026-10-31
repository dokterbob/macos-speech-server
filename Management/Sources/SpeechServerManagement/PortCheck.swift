import Darwin
import Foundation

public enum PortCheck {
    /// Diagnostic only: the server bind remains authoritative because another process can race us.
    public static func check(host: String, port: Int) throws {
        guard port > 0 else { return }
        var hints = addrinfo()
        hints.ai_flags = AI_PASSIVE
        hints.ai_socktype = SOCK_STREAM
        var addresses: UnsafeMutablePointer<addrinfo>?
        let result = getaddrinfo(host, String(port), &hints, &addresses)
        guard result == 0, let first = addresses else { throw ManagementError("Cannot resolve host '\(host)'.") }
        defer { freeaddrinfo(first) }
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let address = current {
            let fd = socket(address.pointee.ai_family, SOCK_STREAM, 0)
            if fd >= 0 {
                var yes: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
                let bound = bind(fd, address.pointee.ai_addr, address.pointee.ai_addrlen)
                let failure = errno
                close(fd)
                if bound != 0 {
                    let detail =
                        failure == EADDRINUSE
                        ? "Another service is using this address. If you installed the Homebrew CLI, stop it yourself or choose another port."
                        : String(cString: strerror(failure))
                    throw ManagementError("Cannot listen on \(host):\(port). \(detail)")
                }
            }
            current = address.pointee.ai_next
        }
    }
}
