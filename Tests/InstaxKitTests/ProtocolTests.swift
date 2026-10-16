import CoreImage
import InstaxFake
import XCTest
@testable import InstaxKit

final class ProtocolTests: XCTestCase {
    func testCommandPacketMatchesPythonReference() {
        // instax_sp2.encode_command(192, b"", 0, 1111).hex()
        XCTAssertEqual(Packet.command(.version).map { String(format: "%02x", $0) }.joined(),
                       "24c00010000000000457" + "0000" + String(format: "%04x", ~(0x24 + 0xc0 + 0x10 + 0x04 + 0x57) & 0xFFFF) + "0d0a")
        let p = Packet.command(.prePrint, payload: [0, 0, 0, 3], session: 0x12345678, pin: 1111)
        XCTAssertTrue(Packet.isValid(p))
        XCTAssertEqual(p.count, 20)
        XCTAssertEqual(Array(p[2...3]), [0, 20])
    }

    func testReplyParsing() {
        let r = Reply(Packet.reply(192, session: 9, returnCode: 163, ejecting: 1, battery: 3, printsLeft: 6, payload: [1, 2, 3, 4]))
        XCTAssertTrue(Packet.isValid(r.raw))
        XCTAssertEqual(r.type, 192)
        XCTAssertEqual(r.returnCode, 163)
        XCTAssertEqual(r.message, "Printing")
        XCTAssertEqual(r.ejecting, 1)
        XCTAssertEqual(r.battery, 3)
        XCTAssertEqual(r.printsLeft, 6)
        XCTAssertEqual(r.payload, [1, 2, 3, 4])
    }

    func testImageLayoutRoundTripAndCorners() {
        var rgba = [UInt8](repeating: 0, count: SP2.width * SP2.height * 4)
        for i in 0..<(SP2.width * SP2.height) { rgba[i * 4] = UInt8(i % 251); rgba[i * 4 + 1] = UInt8(i % 13); rgba[i * 4 + 2] = UInt8(i % 7); rgba[i * 4 + 3] = 255 }
        let out = ImageLayout.encode(rgba: rgba)
        XCTAssertEqual(out.count, 1_440_000)
        XCTAssertEqual(ImageLayout.decode(out), rgba)
        // First landscape column = bottom row of the portrait, left to right.
        let bottomLeft = (SP2.height - 1) * SP2.width
        XCTAssertEqual(out[0], rgba[bottomLeft * 4])
        XCTAssertEqual(out[600], rgba[bottomLeft * 4 + 1])
        XCTAssertEqual(out[1200], rgba[bottomLeft * 4 + 2])
        XCTAssertEqual(out[599], rgba[(bottomLeft + 599) * 4])
    }

    func testStatusAgainstFakeServer() throws {
        let server = try FakeSP2Server()
        server.start()
        defer { server.stop() }
        let info = try SP2Client(host: "127.0.0.1", port: server.port, pin: 1111).info()
        XCTAssertEqual(info.model, "SP-2")
        XCTAssertEqual(info.firmware, "01.19")
        XCTAssertEqual(info.battery, 3)
        XCTAssertEqual(info.printsLeft, 6)
        XCTAssertEqual(info.lifetimePrints, 42)
        XCTAssertEqual(info.maxSize.0, 600)
        XCTAssertEqual(info.maxSize.1, 800)
        XCTAssertEqual(info.status, "OK")
        XCTAssertEqual(server.received.map(\.type), [192, 194, 79, 193])
        XCTAssertEqual(Set(server.received.map(\.connection)).count, 1)
        XCTAssertTrue(server.errors.isEmpty, "\(server.errors)")
    }

    func testWrongPIN() throws {
        let server = try FakeSP2Server()
        server.start()
        defer { server.stop() }
        XCTAssertThrowsError(try SP2Client(host: "127.0.0.1", port: server.port, pin: 1234).info()) {
            XCTAssertEqual(($0 as? InstaxError)?.message, "The printer rejected the PIN (default is 1111).")
        }
    }

    func testPrintSequenceAgainstFakeServer() throws {
        let server = try FakeSP2Server()
        server.start()
        defer { server.stop() }

        // Render a real picture through the Core Image pipeline, then send it.
        let photo = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 200))
        var params = PhotoParams()
        params.mode = .fit
        let rgba = PhotoRenderer.shared.renderPrintRGBA(photo, params)
        let data = ImageLayout.encode(rgba: rgba)

        let client = SP2Client(host: "127.0.0.1", port: server.port, pin: 1111)
        client.phaseDelay = 0.01
        var steps = [Double]()
        let left = try client.printImage(data) { p, _ in steps.append(p) }

        XCTAssertEqual(left, 5)
        XCTAssertTrue(server.errors.isEmpty, "\(server.errors)")
        XCTAssertEqual(server.imageData, data, "printer received exactly the encoded picture")
        XCTAssertEqual(steps.last, 1.0)
        XCTAssertEqual(steps, steps.sorted(), "progress only goes up")

        // Phases: one TCP session each, in the official app's order.
        let rec = server.received
        var phases = [[UInt8]]()
        var lastConn = -1
        for r in rec {
            if r.connection != lastConn { phases.append([]); lastConn = r.connection }
            phases[phases.count - 1].append(r.type)
        }
        XCTAssertEqual(phases, [
            [192],
            Array(repeating: 196, count: 8),
            [179],
            [80],
            [81] + Array(repeating: 82, count: 24) + [83],
            [176, 192, 194, 195, 195, 195],
        ])
        XCTAssertEqual(rec.filter { $0.type == 196 }.map(\.payload), (1...8).map { [0, 0, 0, UInt8($0)] })
        XCTAssertEqual(rec.first { $0.type == 179 }?.payload, [1, 0, 0, 0])
        XCTAssertEqual(rec.first { $0.type == 81 }?.payload, [16, 0, 0x00, 0x15, 0xF9, 0x00, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(rec.filter { $0.type == 82 }.map { Array($0.payload[0..<4]) }, (0..<24).map { [0, 0, 0, UInt8($0)] })
        XCTAssertTrue(rec.allSatisfy { $0.pin == 1111 && $0.session == client.session })

        // Fit mode: a 3:2 red picture is centred with white above and below; the middle is red.
        let back = ImageLayout.decode(server.imageData)
        func px(_ x: Int, _ y: Int) -> [UInt8] { Array(back[(y * 600 + x) * 4..<(y * 600 + x) * 4 + 3]) }
        XCTAssertEqual(px(300, 10), [255, 255, 255])
        XCTAssertEqual(px(300, 790), [255, 255, 255])
        XCTAssertEqual(px(300, 400), [255, 0, 0])
    }

    func testRenderOrientation() {
        // Top half red, bottom half blue: the print's row 0 must be red (top first), and a 90° turn puts
        // the red half on the right.
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 400, width: 600, height: 400))
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 600, height: 400))
        let photo = red.composited(over: blue)
        var p = PhotoParams()
        var out = PhotoRenderer.shared.renderPrintRGBA(photo, p)
        XCTAssertEqual(Array(out[0..<3]), [255, 0, 0])
        XCTAssertEqual(Array(out[(799 * 600) * 4..<(799 * 600) * 4 + 3]), [0, 0, 255])
        p.rotation = 90
        out = PhotoRenderer.shared.renderPrintRGBA(photo, p)
        XCTAssertEqual(Array(out[(400 * 600 + 590) * 4..<(400 * 600 + 590) * 4 + 3]), [255, 0, 0])
        XCTAssertEqual(Array(out[(400 * 600 + 10) * 4..<(400 * 600 + 10) * 4 + 3]), [0, 0, 255])
        // Moving right by 100 print pixels in fit mode leaves white at the left edge.
        p = PhotoParams(); p.mode = .fit; p.dx = 100
        out = PhotoRenderer.shared.renderPrintRGBA(photo, p)
        XCTAssertEqual(Array(out[(400 * 600 + 20) * 4..<(400 * 600 + 20) * 4 + 3]), [255, 255, 255])
    }
}
