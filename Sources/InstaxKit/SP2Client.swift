import Foundation

/// Blocking SP-2 client (port of instax_sp2.SP2). Call it from a background thread or Task.
public final class SP2Client {
    public let host: String
    public let port: UInt16
    public let pin: UInt16
    public let timeout: TimeInterval
    public let session: UInt32
    /// Pause between print phases and between status polls (1 s on a real printer; tests shorten it).
    public var phaseDelay: TimeInterval = 1.0
    public var maxPolls = 45

    private var sock: TCPSocket?

    public init(host: String = SP2.host, port: UInt16 = SP2.port, pin: UInt16 = SP2.defaultPIN,
                timeout: TimeInterval = 5.0) {
        self.host = host
        self.port = port
        self.pin = pin
        self.timeout = timeout
        session = UInt32(truncatingIfNeeded: Int64(Date().timeIntervalSince1970 * 1000))
    }

    // MARK: connection

    public func open() throws { sock = try TCPSocket(host: host, port: port, timeout: timeout) }
    public func close() { sock?.close(); sock = nil }

    /// Runs `body` inside one TCP session (like Python's `with self:`).
    @discardableResult
    public func withSession<T>(_ body: () throws -> T) throws -> T {
        try open()
        defer { close() }
        return try body()
    }

    @discardableResult
    public func command(_ cmd: Command, payload: [UInt8] = [], timeout t: TimeInterval? = nil) throws -> Reply {
        guard let sock else { throw InstaxError("Not connected.") }
        if let t { sock.setTimeout(t) }
        defer { if t != nil { sock.setTimeout(timeout) } }
        try sock.send(Packet.command(cmd, payload: payload, session: session, pin: pin))
        let head = try sock.recv(4)
        let length = Int(be16(head, 2))
        guard length >= 20 else { throw InstaxError("Bad reply length \(length).") }
        let raw = head + (try sock.recv(length - 4))
        guard raw[0] == SP2.respStart, Packet.isValid(raw) else {
            throw InstaxError("Bad reply: " + raw.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " "))
        }
        let rep = Reply(raw)
        if rep.returnCode == 247 { throw InstaxError("The printer rejected the PIN (default is 1111).") }
        return rep
    }

    // MARK: queries

    /// Model, firmware, battery, prints left and lifetime prints (one TCP session).
    public func info() throws -> PrinterInfo {
        let (ver, model, specs, count) = try withSession {
            (try command(.version), try command(.model), try command(.specs), try command(.printCount))
        }
        let fmt = { (v: UInt16) in String(format: "%02X.%02X", v >> 8, v & 0xFF) }
        let modelName = String(decoding: model.raw[16..<min(20, model.raw.count - 4)], as: UTF8.self)
        return PrinterInfo(model: modelName, firmware: fmt(ver.u16(18)), hardware: fmt(ver.u16(20)),
                           battery: ver.battery, printsLeft: ver.printsLeft,
                           lifetimePrints: Int(count.u32(16)),
                           maxSize: (Int(specs.u16(16)), Int(specs.u16(18))), status: ver.message)
    }

    // MARK: printing

    /// Prints SP-2 image bytes (see ImageLayout.encode). Follows the official app's sequence, one TCP
    /// session per phase. Returns the number of prints left afterwards.
    public func printImage(_ data: [UInt8], progress: (Double, String) -> Void = { _, _ in }) throws -> Int {
        guard data.count == SP2.imageBytes else { throw InstaxError("Image must be \(SP2.imageBytes) bytes.") }
        progress(0.02, "Checking printer…")
        let st = try withSession { try command(.version) }
        if st.printsLeft == 0 { throw InstaxError("No prints left: load a new film pack.") }
        if !st.ok { throw InstaxError("Printer not ready: \(st.message)") }

        progress(0.05, "Preparing printer…")
        try withSession {
            for n in UInt16(1)...8 {
                var p: [UInt8] = [0, 0]
                p.appendBE16(n)
                try command(.prePrint, payload: p)
            }
        }
        pause()
        try withSession {
            let rep = try command(.lockDevice, payload: [1, 0, 0, 0])
            if !rep.ok { throw InstaxError("Could not lock the printer: \(rep.message)") }
        }
        pause()
        try withSession { try command(.reset) }
        pause()

        progress(0.10, "Sending picture…")
        try withSession {
            var prep: [UInt8] = [16, 0]
            prep.appendBE32(UInt32(SP2.imageBytes))
            prep += [0, 0, 0, 0, 0, 0]
            let rep = try command(.prepImage, payload: prep)
            if !rep.ok { throw InstaxError("Printer refused the picture: \(rep.message)") }
            for seg in 0..<SP2.segments {
                var p = [UInt8]()
                p.reserveCapacity(4 + SP2.segment)
                p.appendBE32(UInt32(seg))
                p += data[(seg * SP2.segment)..<((seg + 1) * SP2.segment)]
                let r = try command(.sendImage, payload: p, timeout: 15)
                if !r.ok { throw InstaxError("Transfer failed at part \(seg + 1): \(r.message)") }
                progress(0.10 + 0.70 * Double(seg + 1) / Double(SP2.segments), "Sending picture… \(seg + 1)/\(SP2.segments)")
            }
            try command(.t83)
        }

        progress(0.82, "Printing…")
        pause()
        return try withSession {
            try command(.setLockState)
            try command(.version)
            try command(.model)
            for _ in 0..<maxPolls {
                let rep = try command(.t195)
                if rep.returnCode == 0 {
                    progress(1.0, "Done! Wait for the photo to develop.")
                    return rep.printsLeft
                }
                progress(0.85, "Printing… (\(rep.message))")
                pause()
            }
            throw InstaxError("Timed out waiting for the print to finish.")
        }
    }

    private func pause() { if phaseDelay > 0 { Thread.sleep(forTimeInterval: phaseDelay) } }
}
