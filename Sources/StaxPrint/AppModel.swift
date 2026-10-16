import AppKit
import Foundation
import InstaxKit
import Observation

/// The photo being edited. Each value is its own observed property, so a view only redraws for what it shows.
@MainActor @Observable
final class PhotoEditor {
    var photo: LoadedPhoto?
    var mode: PhotoParams.Mode = .fill
    var rotation = 0
    var zoom = 1.0
    var dx = 0.0
    var dy = 0.0
    var tilt = 0.0
    var brightness = 0.0
    var contrast = 0.0
    var saturation = 0.0

    var params: PhotoParams {
        var p = PhotoParams()
        p.mode = mode; p.rotation = rotation; p.zoom = zoom; p.dx = dx; p.dy = dy; p.tilt = tilt
        p.brightness = brightness; p.contrast = contrast; p.saturation = saturation
        return p
    }

    func resetPosition() { zoom = 1; dx = 0; dy = 0; tilt = 0 }
    func resetAdjustments() { brightness = 0; contrast = 0; saturation = 0 }
    func rotate() { rotation = (rotation + 90) % 360 }

    /// dx/dy in print pixels.
    func move(by x: Double, _ y: Double) { dx += x; dy += y }
    func zoom(by f: Double) { zoom = min(8, max(0.2, zoom * f)) }
    func tilt(by deg: Double) { tilt = max(-180, min(180, tilt + deg)) }
}

@MainActor @Observable
final class AppModel {
    // Where the printer is. INSTAX_HOST / INSTAX_PORT point the app at a fake printer for testing.
    let host = ProcessInfo.processInfo.environment["INSTAX_HOST"] ?? SP2.host
    let port = ProcessInfo.processInfo.environment["INSTAX_PORT"].flatMap { UInt16($0) } ?? SP2.port

    // 1 · Wi-Fi
    var ssid: String
    var wifiPassword: String
    var homeNetworks: [String] = []
    var homeNetwork: String
    var reachable = false
    var wifiBusy = false

    // 2 · Printer
    var pin: String
    var info: PrinterInfo?
    var connecting = false

    // 3 · Photo
    let editor = PhotoEditor()
    var printing = false
    var progress = 0.0
    var progressText = ""

    var log: [String] = []
    var alert: String?

    private let defaults = UserDefaults.standard
    private var pollTimer: Timer?
    private let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/StaxPrint.log")

    init() {
        ssid = defaults.string(forKey: "ssid") ?? "INSTAX-"
        wifiPassword = defaults.string(forKey: "wifipw") ?? ""
        homeNetwork = defaults.string(forKey: "home") ?? ""
        pin = defaults.string(forKey: "pin") ?? String(SP2.defaultPIN)
        addLog("Join the printer's Wi-Fi, then press Connect.")
        if host != SP2.host || port != SP2.port { addLog("Using printer at \(host):\(port) (INSTAX_HOST / INSTAX_PORT).") }
        Task.detached {
            let nets = WiFi.savedNetworks().filter { !$0.uppercased().hasPrefix("INSTAX") }
            await MainActor.run {
                self.homeNetworks = nets
                if !nets.contains(self.homeNetwork) { self.homeNetwork = nets.first ?? "" }
            }
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        poll()
        let env = ProcessInfo.processInfo.environment
        if let path = env["INSTAX_OPEN"] { open(url: URL(fileURLWithPath: path)) }
        // Self-test against a fake printer only (instax-tool fake-server): connect, then print without asking.
        if env["INSTAX_SELFTEST"] == "1" && host == "127.0.0.1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.connect() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.printPhoto() }
        }
    }

    // MARK: helpers

    func addLog(_ s: String) {
        log.append(s)
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let line = "\(f.string(from: Date())) \(s)\n"
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.data(using: .utf8)!.write(to: logURL)
        }
    }

    func fail(_ msg: String) {
        addLog("✖ " + msg)
        alert = msg
    }

    var pinValue: UInt16 { UInt16(pin) ?? SP2.defaultPIN }

    func poll() {
        guard !printing && !connecting else { return }   // don't open extra connections mid-job
        let host = host, port = port
        Task.detached(priority: .utility) {
            let ok = TCPSocket.reachable(host: host, port: port)
            await MainActor.run { if self.reachable != ok { self.reachable = ok } }
        }
    }

    // MARK: Wi-Fi

    func joinPrinter() {
        let ssid = ssid.trimmingCharacters(in: .whitespaces), pw = wifiPassword
        guard !ssid.isEmpty, ssid.uppercased() != "INSTAX-" else {
            alert = "Enter the printer's network name, e.g. INSTAX-12345678."
            return
        }
        defaults.set(ssid, forKey: "ssid"); defaults.set(pw, forKey: "wifipw"); defaults.set(homeNetwork, forKey: "home")
        addLog("Joining \(ssid)… (Wi-Fi internet drops while connected)")
        joinWiFi(ssid, pw) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self?.poll() }
        }
    }

    func joinHome() {
        guard !homeNetwork.isEmpty else { return }
        defaults.set(homeNetwork, forKey: "home")
        addLog("Rejoining \(homeNetwork)…")
        joinWiFi(homeNetwork, "") { [weak self] in self?.poll() }
    }

    private func joinWiFi(_ ssid: String, _ pw: String, then: @escaping @MainActor () -> Void) {
        wifiBusy = true
        Task.detached {
            do {
                let msg = try WiFi.join(ssid, password: pw)
                await MainActor.run {
                    self.wifiBusy = false
                    self.addLog("Joined \(ssid).\(msg.isEmpty ? "" : " " + msg)")
                    then()
                }
            } catch {
                await MainActor.run { self.wifiBusy = false; self.fail(error.localizedDescription) }
            }
        }
    }

    // MARK: printer

    func connect() {
        defaults.set(pin, forKey: "pin")
        addLog("Connecting to printer…")
        connecting = true
        let client = SP2Client(host: host, port: port, pin: pinValue)
        Task.detached {
            do {
                let info = try client.info()
                await MainActor.run {
                    self.connecting = false
                    self.info = info
                    self.addLog("Connected: \(info.model), \(info.printsLeft) prints left, battery level \(info.battery).")
                }
            } catch {
                await MainActor.run { self.connecting = false; self.fail(error.localizedDescription) }
            }
        }
    }

    // MARK: photo

    func open(url: URL) {
        let r = PhotoRenderer.shared
        Task.detached(priority: .userInitiated) {
            do {
                let photo = try r.load(url: url)
                await MainActor.run {
                    self.editor.photo = photo
                    self.editor.rotation = 0
                    self.editor.resetPosition()
                    self.addLog("Loaded \(url.lastPathComponent) (\(photo.width)×\(photo.height), \(photo.note))")
                }
            } catch {
                await MainActor.run { self.fail("Could not open the image:\n\(error.localizedDescription)") }
            }
        }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if let dir = defaults.string(forKey: "dir") { panel.directoryURL = URL(fileURLWithPath: dir) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        defaults.set(url.deletingLastPathComponent().path, forKey: "dir")
        open(url: url)
    }

    var printQuestion: String {
        guard let n = info?.printsLeft else { return "Print this photo?" }
        return "Print this photo? It uses 1 of the \(n) prints left."
    }

    func printPhoto() {
        guard let photo = editor.photo else { return }
        let params = editor.params
        let client = SP2Client(host: host, port: port, pin: pinValue)
        if host == "127.0.0.1" { client.phaseDelay = 0.2 }
        printing = true
        progress = 0
        progressText = "Rendering…"
        addLog("Printing…")
        Task.detached(priority: .userInitiated) {
            do {
                let rgba = PhotoRenderer.shared.renderPrintRGBA(photo, params)
                let data = ImageLayout.encode(rgba: rgba)
                let left = try client.printImage(data) { p, msg in
                    Task { @MainActor in self.progress = p; self.progressText = msg }
                }
                await MainActor.run {
                    self.printing = false
                    self.addLog("✔ Printed. \(left) prints left.")
                    self.info?.printsLeft = left
                }
            } catch {
                await MainActor.run {
                    self.printing = false
                    self.progressText = "Failed"
                    self.fail(error.localizedDescription)
                }
            }
        }
    }
}
