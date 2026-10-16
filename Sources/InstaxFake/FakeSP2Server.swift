import Darwin
import Foundation
import InstaxKit

/// A fake Instax SHARE SP-2: a TCP server on 127.0.0.1 that checks every command packet, answers like the
/// real printer and records what it was sent. Nothing is printed.
public final class FakeSP2Server: @unchecked Sendable {
    public struct Received: Sendable {
        public let connection: Int
        public let type: UInt8
        public let pin: UInt16
        public let session: UInt32
        public let payload: [UInt8]
    }

    public let port: UInt16
    public var pin: UInt16 = SP2.defaultPIN
    public var battery: UInt8 = 3
    public var printsLeft: UInt8 = 6
    public var lifetimePrints: UInt32 = 42
    /// How many T195 polls answer "Printing" before the print is done.
    public var busyPolls = 2
    public var log: (String) -> Void = { _ in }

    private let lock = NSLock()
    private var _received: [Received] = []
    private var _errors: [String] = []
    private var image = [UInt8]()
    private var polls = 0
    private var listenFD: Int32 = -1
    private var connections = 0

    public var received: [Received] { lock.withLock { _received } }
    public var errors: [String] { lock.withLock { _errors } }
    public var imageData: [UInt8] { lock.withLock { image } }

    public init(port: UInt16 = 0) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0, listen(fd, 8) == 0 else { throw InstaxError("fake server: cannot listen on \(port)") }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &len) }
        }
        listenFD = fd
        self.port = UInt16(bigEndian: bound.sin_port)
    }

    public func start() {
        Thread.detachNewThread { [self] in
            while true {
                let fd = accept(listenFD, nil, nil)
                if fd < 0 { return }
                let n = lock.withLock { connections += 1; return connections }
                Thread.detachNewThread { [self] in serve(fd, n) }
            }
        }
    }

    public func resetImage() { lock.withLock { image = [] } }

    public func stop() {
        if listenFD >= 0 { shutdown(listenFD, SHUT_RDWR); close(listenFD); listenFD = -1 }
    }

    private func readExactly(_ fd: Int32, _ n: Int) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: n)
        var got = 0
        while got < n {
            let r = out.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress! + got, n - got, 0) }
            if r <= 0 { return nil }
            got += r
        }
        return out
    }

    private func fail(_ s: String) { lock.withLock { _errors.append(s) }; log("ERROR " + s) }

    private func serve(_ fd: Int32, _ conn: Int) {
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        while let head = readExactly(fd, 4) {
            let length = Int(head[2]) << 8 | Int(head[3])
            guard head[0] == SP2.cmdStart, length >= 16, let rest = readExactly(fd, length - 4) else {
                fail("bad header \(head)"); return
            }
            // The length field counts the whole packet, checksum and CRLF included.
            let pkt = head + rest
            guard Packet.isValid(pkt) else { fail("bad checksum / trailer for type \(head[1])"); return }
            let session = UInt32(pkt[4]) << 24 | UInt32(pkt[5]) << 16 | UInt32(pkt[6]) << 8 | UInt32(pkt[7])
            let pin = UInt16(pkt[8]) << 8 | UInt16(pkt[9])
            let payload = Array(pkt[12..<(pkt.count - 4)])   // command header is 12 bytes
            let type = pkt[1]
            lock.withLock { _received.append(Received(connection: conn, type: type, pin: pin, session: session, payload: payload)) }
            log("conn \(conn): type \(type) (\(Command(rawValue: type).map { "\($0)" } ?? "?")) payload \(payload.count) B")
            let reply = answer(type: type, pin: pin, session: session, payload: payload)
            let sent = reply.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!, $0.count, 0) }
            if sent != reply.count { return }
        }
    }

    private func answer(type: UInt8, pin: UInt16, session: UInt32, payload: [UInt8]) -> [UInt8] {
        func r(_ rc: UInt8 = 0, _ p: [UInt8] = []) -> [UInt8] {
            Packet.reply(type, session: session, returnCode: rc, battery: battery, printsLeft: printsLeft, payload: p)
        }
        if pin != self.pin { return r(247) }
        switch Command(rawValue: type) {
        case .version: return r(0, [0, 0, 0x01, 0x19, 0x02, 0x00, 0, 0])
        case .model: return r(0, Array("SP-2".utf8) + [0, 0, 0, 0])
        case .specs: return r(0, [0x02, 0x58, 0x03, 0x20, 0, 0, 0, 0])
        case .printCount:
            var p = [UInt8](); p.appendBE32Public(lifetimePrints); p += [0, 0, 0, 0]
            return r(0, p)
        case .prepImage:
            lock.withLock { image = [] }
            return r(0, [0, 0, 0, 0])
        case .sendImage:
            guard payload.count == 4 + SP2.segment else { fail("segment size \(payload.count)"); return r(161) }
            let seq = Int(payload[0]) << 24 | Int(payload[1]) << 16 | Int(payload[2]) << 8 | Int(payload[3])
            lock.withLock {
                if seq * SP2.segment != image.count { _errors.append("segment \(seq) out of order") }
                image += payload[4...]
            }
            return r(0, Array(payload[0..<4]))
        case .t195:
            let busy = lock.withLock { () -> Bool in polls += 1; return polls <= busyPolls }
            if busy { return r(163) }
            lock.withLock { if printsLeft > 0 { printsLeft -= 1 }; lifetimePrints += 1; polls = 0 }
            return r(0)
        case .some: return r(0)
        case .none: fail("unknown command \(type)"); return r(0)
        }
    }
}

extension Array where Element == UInt8 {
    mutating func appendBE32Public(_ v: UInt32) {
        append(UInt8(v >> 24)); append(UInt8((v >> 16) & 0xFF)); append(UInt8((v >> 8) & 0xFF)); append(UInt8(v & 0xFF))
    }
}
