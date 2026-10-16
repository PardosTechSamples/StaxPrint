import Foundation

/// macOS Wi-Fi helpers built on `networksetup` (same approach as the Python app).
enum WiFi {
    @discardableResult
    static func run(_ args: [String], timeout: TimeInterval = 40) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let deadline = Date().addingTimeInterval(timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate() }
        return (p.isRunning ? -1 : p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static let device: String = {
        let lines = run(["-listallhardwareports"], timeout: 10).output.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() where line.contains("Wi-Fi") && i + 1 < lines.count {
            if let dev = lines[i + 1].split(separator: ":", maxSplits: 1).last {
                return dev.trimmingCharacters(in: .whitespaces)
            }
        }
        return "en0"
    }()

    static func savedNetworks() -> [String] {
        run(["-listpreferredwirelessnetworks", device], timeout: 10).output
            .components(separatedBy: "\n").dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func join(_ ssid: String, password: String = "") throws -> String {
        var args = ["-setairportnetwork", device, ssid]
        if !password.isEmpty { args.append(password) }
        let r = run(args)
        if r.status != 0 || r.output.contains("Could not") || r.output.contains("Failed") || r.output.contains("Error") {
            throw NSError(domain: "WiFi", code: Int(r.status),
                          userInfo: [NSLocalizedDescriptionKey: r.output.isEmpty ? "Could not join \(ssid)" : r.output])
        }
        return r.output
    }
}
