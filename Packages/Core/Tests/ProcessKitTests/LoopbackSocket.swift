import Darwin
import Foundation

/// A socket bound to the loopback interface, for the tests that look at what the system says about sockets.
///
/// The address is `127.0.0.1` or `::1`, so nothing is reachable from the network and no firewall asks about it. The
/// socket is closed by `close()`, which the test calls in a `defer`.
struct LoopbackSocket {
    enum Kind { case tcp, udp }
    enum Family { case ipv4, ipv6 }

    let descriptor: Int32
    private let family: Family

    /// A socket bound to `port`, or to a port that the system picks if that is 0.
    init(_ kind: Kind, _ family: Family = .ipv4, port: UInt16 = 0) throws {
        let descriptor = socket(family == .ipv4 ? AF_INET : AF_INET6, kind == .tcp ? SOCK_STREAM : SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw POSIXError(errno: errno) }
        let status = Self.withAddress(family, port: port) { bind(descriptor, $0, $1) }
        guard status == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw POSIXError(errno: code)
        }
        self.descriptor = descriptor
        self.family = family
    }

    /// A TCP socket that listens.
    static func listening(_ family: Family = .ipv4, port: UInt16 = 0) throws -> LoopbackSocket {
        let socket = try LoopbackSocket(.tcp, family, port: port)
        guard Darwin.listen(socket.descriptor, 8) == 0 else {
            let code = errno
            socket.close()
            throw POSIXError(errno: code)
        }
        return socket
    }

    /// The port that the socket is bound to.
    var port: UInt16 {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let status = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard status == 0 else { return 0 }
        // `sin_port` and `sin6_port` are both the third and fourth byte of their structure.
        return withUnsafeBytes(of: &storage) { UInt16(bigEndian: $0.loadUnaligned(fromByteOffset: 2, as: UInt16.self)) }
    }

    /// Connects to a TCP socket that listens on `port`. The connection is made when this returns, whether or not the
    /// other side has accepted it.
    func connect(to port: UInt16) throws {
        let status = Self.withAddress(family, port: port) { Darwin.connect(descriptor, $0, $1) }
        guard status == 0 else { throw POSIXError(errno: errno) }
    }

    func close() {
        Darwin.close(descriptor)
    }

    private static func withAddress<T>(
        _ family: Family, port: UInt16, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
    ) -> T {
        switch family {
        case .ipv4:
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)  // 127.0.0.1
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    body($0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        case .ipv6:
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            inet_pton(AF_INET6, "::1", &address.sin6_addr)
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    body($0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
    }
}
