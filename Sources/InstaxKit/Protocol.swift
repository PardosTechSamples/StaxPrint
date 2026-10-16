// Fujifilm Instax SHARE SP-2 Wi-Fi protocol.
//
// Ported from instax/instax_sp2.py, which follows jpwsutton/instax_api
// (MIT License, Copyright (c) 2016 James Sutton).
//
//   Command : 24 <type> <len16> <session32> <pin16> 00 00 <payload> <~sum16> 0D 0A
//   Reply   : 2A <type> <len16> <session32> 00 00 00 00 <rc> 00 <eject> <batt<<4 | prints_left> <payload> <~sum16> 0D 0A
//   (all big-endian; sum16 is the byte sum of everything before it, sent inverted)

import Foundation

public enum SP2 {
    public static let host = "192.168.0.251"
    public static let port: UInt16 = 8080
    public static let defaultPIN: UInt16 = 1111

    public static let cmdStart: UInt8 = 0x24
    public static let respStart: UInt8 = 0x2A

    public static let width = 600                       // portrait, as the photo comes out of the printer
    public static let height = 800
    public static let imageBytes = width * height * 3   // 1,440,000
    public static let segment = 60_000
    public static var segments: Int { imageBytes / segment }

    public static let returnCodes: [UInt8: String] = [
        0: "OK", 248: "Sensor error", 247: "Wrong PIN", 246: "Motor error", 245: "Cam point error",
        244: "Film pack is empty", 243: "Frame error 1", 242: "Frame error 2", 241: "Frame error 3",
        240: "Frame error 4", 224: "Connection error", 180: "Charging", 165: "Testing", 164: "Ejecting",
        163: "Printing", 162: "Battery is empty", 161: "Not image data", 160: "Printer is in use by another device",
        127: "Updating",
    ]

    public static func message(for code: UInt8) -> String {
        returnCodes[code] ?? "Error \(code)"
    }
}

public enum Command: UInt8, CaseIterable, Sendable {
    case specs = 79, reset = 80, prepImage = 81, sendImage = 82, t83 = 83
    case setLockState = 176, lockDevice = 179, version = 192, printCount = 193, model = 194, t195 = 195, prePrint = 196
}

public struct InstaxError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// MARK: - big-endian helpers

extension Array where Element == UInt8 {
    mutating func appendBE16(_ v: UInt16) { append(UInt8(v >> 8)); append(UInt8(v & 0xFF)) }
    mutating func appendBE32(_ v: UInt32) {
        append(UInt8(v >> 24)); append(UInt8((v >> 16) & 0xFF)); append(UInt8((v >> 8) & 0xFF)); append(UInt8(v & 0xFF))
    }
}

@inline(__always) func be16(_ b: [UInt8], _ off: Int) -> UInt16 { UInt16(b[off]) << 8 | UInt16(b[off + 1]) }
@inline(__always) func be32(_ b: [UInt8], _ off: Int) -> UInt32 {
    UInt32(b[off]) << 24 | UInt32(b[off + 1]) << 16 | UInt32(b[off + 2]) << 8 | UInt32(b[off + 3])
}

func byteSum(_ bytes: some Sequence<UInt8>) -> Int { bytes.reduce(0) { $0 &+ Int($1) } }

// MARK: - packets

public enum Packet {
    /// Encodes a command packet exactly like instax_sp2.encode_command.
    public static func command(_ type: UInt8, payload: [UInt8] = [], session: UInt32 = 0,
                               pin: UInt16 = SP2.defaultPIN) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(20 + payload.count)
        out.append(SP2.cmdStart)
        out.append(type)
        out.appendBE16(UInt16(16 + payload.count))
        out.appendBE32(session)
        out.appendBE16(pin)
        out.append(0); out.append(0)
        out.append(contentsOf: payload)
        out.appendBE16(UInt16(truncatingIfNeeded: ~byteSum(out)))
        out.append(0x0D); out.append(0x0A)
        return out
    }

    public static func command(_ cmd: Command, payload: [UInt8] = [], session: UInt32 = 0,
                               pin: UInt16 = SP2.defaultPIN) -> [UInt8] {
        command(cmd.rawValue, payload: payload, session: session, pin: pin)
    }

    /// Encodes a printer reply (used by the fake server and tests).
    public static func reply(_ type: UInt8, session: UInt32, returnCode: UInt8 = 0, ejecting: UInt8 = 0,
                             battery: UInt8 = 3, printsLeft: UInt8 = 10, payload: [UInt8] = []) -> [UInt8] {
        var out = [UInt8]()
        out.append(SP2.respStart)
        out.append(type)
        out.appendBE16(UInt16(16 + payload.count + 4))
        out.appendBE32(session)
        out.append(contentsOf: [0, 0, 0, 0])
        out.append(returnCode)
        out.append(0)
        out.append(ejecting << 2)
        out.append((battery & 7) << 4 | (printsLeft & 15))
        out.append(contentsOf: payload)
        out.appendBE16(UInt16(truncatingIfNeeded: ~byteSum(out)))
        out.append(0x0D); out.append(0x0A)
        return out
    }

    /// Same check as instax_sp2.valid_packet: CRLF trailer and sum + checksum == 0xFFFF.
    public static func isValid(_ p: [UInt8]) -> Bool {
        guard p.count >= 16, p[p.count - 2] == 0x0D, p[p.count - 1] == 0x0A else { return false }
        return (byteSum(p[0..<(p.count - 4)]) + Int(be16(p, p.count - 4))) & 0xFFFF == 0xFFFF
    }
}

public struct Reply: Sendable {
    public let raw: [UInt8]
    public init(_ raw: [UInt8]) { self.raw = raw }

    public var type: UInt8 { raw[1] }
    public var returnCode: UInt8 { raw[12] }
    public var ejecting: UInt8 { raw[14] >> 2 }
    public var battery: Int { Int((raw[15] >> 4) & 7) }
    public var printsLeft: Int { Int(raw[15] & 15) }
    public var payload: [UInt8] { Array(raw[16..<(raw.count - 4)]) }
    public var ok: Bool { returnCode == 0 }
    public var message: String { SP2.message(for: returnCode) }
    public func u16(_ off: Int) -> UInt16 { be16(raw, off) }
    public func u32(_ off: Int) -> UInt32 { be32(raw, off) }
}

public struct PrinterInfo: Sendable, Equatable {
    public var model: String
    public var firmware: String
    public var hardware: String
    public var battery: Int
    public var printsLeft: Int
    public var lifetimePrints: Int
    public var maxSize: (Int, Int)
    public var status: String

    public static func == (a: PrinterInfo, b: PrinterInfo) -> Bool {
        a.model == b.model && a.firmware == b.firmware && a.hardware == b.hardware && a.battery == b.battery
            && a.printsLeft == b.printsLeft && a.lifetimePrints == b.lifetimePrints && a.maxSize == b.maxSize
            && a.status == b.status
    }
}
