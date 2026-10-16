import Darwin
import Foundation

/// A small blocking TCP socket with connect/read/write timeouts. Meant to be used off the main thread.
public final class TCPSocket {
    public private(set) var fd: Int32

    public init(host: String, port: UInt16, timeout: TimeInterval) throws {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { throw InstaxError("Bad IP address \(host)") }

        fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw InstaxError("socket(): \(String(cString: strerror(errno)))") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))

        // Non-blocking connect so it can time out quickly when the printer isn't there.
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 {
            guard errno == EINPROGRESS else { let e = errno; Darwin.close(fd); throw Self.error("connect", e, host, port) }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let n = poll(&pfd, 1, Int32(timeout * 1000))
            if n <= 0 { Darwin.close(fd); throw InstaxError("Could not reach the printer at \(host):\(port) (timed out).") }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            if err != 0 { Darwin.close(fd); throw Self.error("connect", err, host, port) }
        }
        _ = fcntl(fd, F_SETFL, flags)
        setTimeout(timeout)
    }

    deinit { close() }

    private static func error(_ what: String, _ e: Int32, _ host: String, _ port: UInt16) -> InstaxError {
        InstaxError("Could not reach the printer at \(host):\(port) (\(String(cString: strerror(e)))).")
    }

    public func setTimeout(_ t: TimeInterval) {
        var tv = timeval(tv_sec: Int(t), tv_usec: Int32((t - floor(t)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    public func send(_ bytes: [UInt8]) throws {
        var sent = 0
        try bytes.withUnsafeBytes { buf in
            while sent < buf.count {
                let n = Darwin.send(fd, buf.baseAddress! + sent, buf.count - sent, 0)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw InstaxError(errno == EAGAIN ? "Timed out sending to the printer." :
                        "Send failed: \(String(cString: strerror(errno)))")
                }
                sent += n
            }
        }
    }

    /// Reads exactly n bytes.
    public func recv(_ n: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: n)
        var got = 0
        try out.withUnsafeMutableBytes { buf in
            while got < n {
                let r = Darwin.recv(fd, buf.baseAddress! + got, n - got, 0)
                if r == 0 { throw InstaxError("The printer closed the connection.") }
                if r < 0 {
                    if errno == EINTR { continue }
                    throw InstaxError(errno == EAGAIN ? "Timed out waiting for the printer." :
                        "Receive failed: \(String(cString: strerror(errno)))")
                }
                got += r
            }
        }
        return out
    }

    public func close() {
        guard fd >= 0 else { return }
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        fd = -1
    }

    /// True if something accepts TCP connections at host:port within the timeout.
    public static func reachable(host: String = SP2.host, port: UInt16 = SP2.port, timeout: TimeInterval = 0.6) -> Bool {
        (try? TCPSocket(host: host, port: port, timeout: timeout)) != nil
    }
}
