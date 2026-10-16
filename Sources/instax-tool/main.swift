// instax-tool: command-line helper for StaxPrint.
//
//   instax-tool status [--host H] [--port P] [--pin N]      query the printer (no film used)
//   instax-tool encode-command <type> <payload-hex> <session> <pin>   print a command packet as hex
//   instax-tool encode-image <in.rgb> <out.bin>              600x800 RGB file -> SP-2 bytes
//   instax-tool render <photo> <out.png> [key=value …]       render the 600x800 print (mode, rotation,
//                                                            zoom, dx, dy, tilt, brightness, contrast, saturation)
//   instax-tool fake-server [port]                           run a fake SP-2 on 127.0.0.1 (default 8080)

import CoreImage
import Metal
import QuartzCore
import Foundation
import InstaxFake
import InstaxKit

func die(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(1) }
func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
func unhex(_ s: String) -> [UInt8] {
    var out = [UInt8](), chars = Array(s)
    var i = 0
    while i + 1 < chars.count { out.append(UInt8(String(chars[i...i + 1]), radix: 16)!); i += 2 }
    return out
}

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...i + 1)
    return v
}

guard let cmd = args.first else { die("usage: instax-tool status|encode-command|encode-image|render|fake-server …") }
args.removeFirst()

switch cmd {
case "status":
    let host = option("--host") ?? SP2.host
    let port = option("--port").flatMap { UInt16($0) } ?? SP2.port
    let pin = option("--pin").flatMap { UInt16($0) } ?? SP2.defaultPIN
    do {
        let i = try SP2Client(host: host, port: port, pin: pin).info()
        print("model:          \(i.model)")
        print("firmware:       \(i.firmware)  hardware: \(i.hardware)")
        print("battery level:  \(i.battery)")
        print("prints left:    \(i.printsLeft) / 10")
        print("lifetime:       \(i.lifetimePrints)")
        print("max size:       \(i.maxSize.0) x \(i.maxSize.1)")
        print("status:         \(i.status)")
    } catch { die("error: \(error.localizedDescription)") }

case "encode-command":
    guard args.count == 4, let t = UInt8(args[0]), let s = UInt32(args[2]), let p = UInt16(args[3]) else {
        die("usage: encode-command <type> <payload-hex|-> <session> <pin>")
    }
    print(hex(Packet.command(t, payload: args[1] == "-" ? [] : unhex(args[1]), session: s, pin: p)))

case "encode-image":
    guard args.count == 2, let rgb = FileManager.default.contents(atPath: args[0]) else { die("usage: encode-image in.rgb out.bin") }
    guard rgb.count == SP2.imageBytes else { die("expected \(SP2.imageBytes) bytes of 600x800 RGB") }
    var rgba = [UInt8](repeating: 255, count: SP2.width * SP2.height * 4)
    let src = [UInt8](rgb)
    do {
        for i in 0..<(SP2.width * SP2.height) {
            rgba[i * 4] = src[i * 3]; rgba[i * 4 + 1] = src[i * 3 + 1]; rgba[i * 4 + 2] = src[i * 3 + 2]
        }
    }
    let t0 = Date()
    let out = ImageLayout.encode(rgba: rgba)
    FileManager.default.createFile(atPath: args[1], contents: Data(out))
    FileHandle.standardError.write("encoded in \(Int(Date().timeIntervalSince(t0) * 1000)) ms\n".data(using: .utf8)!)

case "render":
    guard args.count >= 2 else { die("usage: render <photo> <out.png> [key=value …]") }
    var p = PhotoParams()
    for kv in args.dropFirst(2) {
        let parts = kv.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { die("bad option \(kv)") }
        let v = Double(parts[1]) ?? 0
        switch parts[0] {
        case "mode": p.mode = PhotoParams.Mode(rawValue: parts[1]) ?? .fill
        case "rotation": p.rotation = Int(v)
        case "zoom": p.zoom = v
        case "dx": p.dx = v
        case "dy": p.dy = v
        case "tilt": p.tilt = v
        case "brightness": p.brightness = v
        case "contrast": p.contrast = v
        case "saturation": p.saturation = v
        default: die("unknown option \(parts[0])")
        }
    }
    let r = PhotoRenderer.shared
    do {
        let photo = try r.load(url: URL(fileURLWithPath: args[0]))
        FileHandle.standardError.write("loaded \(photo.width)x\(photo.height), \(photo.note)\n".data(using: .utf8)!)
        let t0 = Date()
        let rgba = r.renderPrintRGBA(photo, p)
        FileHandle.standardError.write("rendered in \(Int(Date().timeIntervalSince(t0) * 1000)) ms\n".data(using: .utf8)!)
        try r.writePNG(r.cgImage(rgba: rgba)!, to: URL(fileURLWithPath: args[1]))
    } catch { die("error: \(error.localizedDescription)") }

case "bench":
    // Times preview frames as the app draws them: compose at 750x1000 (375x500 pt on Retina) into a Metal texture.
    guard let path = args.first else { die("usage: bench <photo>") }
    let r = PhotoRenderer.shared
    guard let dev = r.device, let queue = dev.makeCommandQueue() else { die("no Metal device") }
    do {
        let photo = try r.load(url: URL(fileURLWithPath: path))
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 750, height: 1000, mipmapped: false)
        desc.usage = [.shaderWrite, .renderTarget, .shaderRead]
        let tex = dev.makeTexture(descriptor: desc)!
        var times = [Double]()
        for i in 0..<240 {
            var p = PhotoParams()
            p.zoom = 1 + Double(i % 60) / 30; p.dx = Double(i % 40) - 20; p.tilt = Double(i % 90) - 45
            p.brightness = Double(i % 100) - 50; p.saturation = Double(i % 50); p.contrast = Double(i % 30) - 15
            let t0 = CACurrentMediaTime()
            let cb = queue.makeCommandBuffer()!
            let dest = CIRenderDestination(width: 750, height: 1000, pixelFormat: .bgra8Unorm, commandBuffer: cb) { tex }
            dest.colorSpace = r.srgb
            _ = try r.context.startTask(toRender: r.compose(photo, p, outWidth: 750, outHeight: 1000), to: dest)
            cb.commit()
            cb.waitUntilCompleted()
            if i >= 10 { times.append((CACurrentMediaTime() - t0) * 1000) }
        }
        times.sort()
        print(String(format: "%d frames: median %.2f ms, p95 %.2f ms, max %.2f ms (CPU+GPU, waited)",
                     times.count, times[times.count / 2], times[times.count * 95 / 100], times.last!))
    } catch { die("error: \(error.localizedDescription)") }

case "fake-server":
    let port = args.first.flatMap { UInt16($0) } ?? 8080
    do {
        let s = try FakeSP2Server(port: port)
        s.log = { print($0) }
        s.start()
        print("Fake SP-2 listening on 127.0.0.1:\(s.port) (PIN \(s.pin)). Ctrl-C to stop.")
        print("Run the app with INSTAX_HOST=127.0.0.1 INSTAX_PORT=\(s.port) to print to it.")
        while true {
            Thread.sleep(forTimeInterval: 1)
            let img = s.imageData
            if img.count == SP2.imageBytes {
                let path = FileManager.default.temporaryDirectory.appendingPathComponent("fake-sp2-print.png").path
                let r = PhotoRenderer.shared
                try? r.writePNG(r.cgImage(rgba: ImageLayout.decode(img))!, to: URL(fileURLWithPath: path))
                print("Received a full picture -> \(path)")
                s.resetImage()
            }
        }
    } catch { die("error: \(error.localizedDescription)") }

default:
    die("unknown command \(cmd)")
}
