import Darwin
import Testing

@testable import ProcessKit

/// What the kernel says about a socket is one structure for all kinds of socket, with a union at the end that holds
/// what belongs to the kind. The tests fill in the structure by hand: a real socket cannot be put into every state, and
/// cannot be made to hold bytes that only look like those of a TCP socket.
@Suite struct SocketInfoTests {
    @Test func aTCPSocketThatListensHasItsPort() {
        #expect(Kernel.listeningPort(in: socket(kind: SOCKINFO_TCP, state: TSI_S_LISTEN, port: 8080)) == 8080)
    }

    @Test func thePortIsReadFromNetworkByteOrder() {
        // 0x1F90 is 8080. Read the other way round it would be 0x901F, which is 36895.
        for port: UInt16 in [1, 80, 256, 4200, 8080, 36895, 49152, 65535] {
            #expect(Kernel.listeningPort(in: socket(kind: SOCKINFO_TCP, state: TSI_S_LISTEN, port: port)) == port)
        }
    }

    @Test func aTCPSocketInAnyOtherStateDoesNotListen() {
        for state in TSI_S_CLOSED...TSI_S_RESERVED where state != TSI_S_LISTEN {
            let info = socket(kind: SOCKINFO_TCP, state: state, port: 8080)
            #expect(Kernel.listeningPort(in: info) == nil, "state \(state)")
        }
    }

    @Test func aSocketThatIsNotTCPHasNoListeningPort() {
        // The union holds something else for these, and its bytes are no TCP state and port, however they look.
        for kind in SOCKINFO_GENERIC...SOCKINFO_VSOCK where kind != SOCKINFO_TCP {
            let info = socket(kind: kind, state: TSI_S_LISTEN, port: 8080)
            #expect(Kernel.listeningPort(in: info) == nil, "kind \(kind)")
        }
    }

    @Test func portZeroIsNoPort() {
        #expect(Kernel.listeningPort(in: socket(kind: SOCKINFO_TCP, state: TSI_S_LISTEN, port: 0)) == nil)
    }

    private func socket(kind: Int, state: Int32, port: UInt16) -> socket_fdinfo {
        var info = socket_fdinfo()
        info.psi.soi_kind = Int32(kind)
        info.psi.soi_proto.pri_tcp.tcpsi_state = state
        // As the kernel keeps it: network byte order, in the low two bytes of an `int`.
        info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport = Int32(port.bigEndian)
        return info
    }
}
