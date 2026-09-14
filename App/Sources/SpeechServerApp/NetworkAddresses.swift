import Darwin
import Foundation

/// Interface addresses for connection instructions; never used for management transport.
enum NetworkAddresses {
    static var localIPv4: [String] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return [] }
        defer { freeifaddrs(interfaces) }
        var current = interfaces
        var addresses: Set<String> = []
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                let address = entry.pointee.ifa_addr, address.pointee.sa_family == AF_INET
            else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(
                address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
                == 0
            {
                let value = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if !value.hasPrefix("169.254.") { addresses.insert(value) }
            }
        }
        return addresses.sorted()
    }
}
