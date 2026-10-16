import InstaxKit
import SwiftUI

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }
}

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    if let mark = Brand.mark {
                        Image(nsImage: mark).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(height: 40)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        (Text("Stax").foregroundColor(Color(red: 0.36, green: 0.62, blue: 0.82))
                            + Text("Print").foregroundColor(Color(red: 0.42, green: 0.66, blue: 0.24)))
                            .font(.system(.title2, design: .rounded).weight(.heavy))
                        Text("for the Fujifilm Instax® SHARE SP-2, over Wi-Fi").font(.caption).foregroundStyle(.secondary)
                    }
                }
                WiFiCard(model: model)
                PrinterCard(model: model)
                LogView(lines: model.log)
            }
            .frame(width: 360)
            PhotoCard(model: model, editor: model.editor)
        }
        .padding(14)
        .alert("StaxPrint", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        } message: {
            Text(model.alert ?? "")
        }
    }
}

struct WiFiCard: View {
    @Bindable var model: AppModel
    var body: some View {
        Card(title: "1 · Printer Wi-Fi") {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("Network")
                    TextField("INSTAX-12345678 (printed on the printer)", text: $model.ssid)
                }
                GridRow {
                    Text("Password")
                    SecureField("Wi-Fi password, if it has one", text: $model.wifiPassword)
                }
            }
            HStack {
                Button("Join printer Wi-Fi") { model.joinPrinter() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.wifiBusy)
                Spacer()
                ReachabilityLight(reachable: model.reachable)
            }
            HStack {
                Picker("", selection: $model.homeNetwork) {
                    ForEach(model.homeNetworks, id: \.self) { Text($0).tag($0) }
                    if model.homeNetworks.isEmpty { Text("No saved networks").tag("") }
                }
                .labelsHidden()
                Button("Back to my Wi-Fi") { model.joinHome() }
                    .disabled(model.wifiBusy || model.homeNetwork.isEmpty)
            }
            if model.wifiBusy { ProgressView().controlSize(.small) }
            Text("While joined, the Wi-Fi link is direct to the printer (no internet over Wi-Fi).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ReachabilityLight: View {
    let reachable: Bool
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(reachable ? Color.green : Color.red).frame(width: 9, height: 9)
            Text(reachable ? "printer reachable" : "printer not reachable")
                .font(.callout.weight(.semibold))
                .foregroundStyle(reachable ? Color.green : Color.red)
        }
        .animation(.easeInOut(duration: 0.2), value: reachable)
    }
}

struct PrinterCard: View {
    @Bindable var model: AppModel
    var body: some View {
        Card(title: "2 · Printer") {
            HStack {
                Text("PIN")
                TextField("1111", text: $model.pin)
                    .frame(width: 60)
                    .help("The SP-2's 4-digit PIN. Factory default: 1111.")
                Button("Connect") { model.connect() }
                    .buttonStyle(.borderedProminent).tint(.green)
                    .disabled(model.connecting || model.printing)
                if model.connecting { ProgressView().controlSize(.small) }
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.info.map { "\($0.printsLeft) / 10" } ?? "– / 10")
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(model.info == nil ? .secondary : .primary)
                    Text("prints left in pack").font(.caption).foregroundStyle(.secondary)
                }
                if let i = model.info {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(i.model)  ·  firmware \(i.firmware)")
                        HStack(spacing: 6) {
                            Text("Battery")
                            BatteryBars(level: i.battery)
                            Text("(level \(i.battery))").foregroundStyle(.secondary)
                        }
                        Text("Lifetime prints: \(i.lifetimePrints)")
                        Text("Status: \(i.status)")
                    }
                    .font(.callout)
                } else {
                    Text("Not connected").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The SP-2 reports battery in a 3-bit field; it appears to use 0-4.
struct BatteryBars: View {
    let level: Int
    var body: some View {
        let top = max(4, level)
        HStack(spacing: 2) {
            ForEach(0..<top, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(i < level ? (level <= 1 ? Color.red : Color.green) : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 12)
            }
        }
    }
}

struct LogView: View {
    let lines: [String]
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        Text(line).id(i).textSelection(.enabled)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(red: 0.53, green: 0.94, blue: 0.67))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .background(Color(red: 0.02, green: 0.06, blue: 0.05), in: RoundedRectangle(cornerRadius: 8))
            .onChange(of: lines.count) { _, n in withAnimation { proxy.scrollTo(n - 1, anchor: .bottom) } }
        }
        .frame(minHeight: 120)
    }
}

struct PhotoCard: View {
    @Bindable var model: AppModel
    @Bindable var editor: PhotoEditor
    @State private var confirmPrint = false
    @State private var dropTarget = false

    static let previewWidth: CGFloat = 375

    var body: some View {
        Card(title: "3 · Photo (600 × 800, as printed)") {
            ZStack {
                PreviewView(editor: editor)
                if editor.photo == nil {
                    Text("Open or drop a photo to preview it").foregroundStyle(.secondary).allowsHitTesting(false)
                }
                if dropTarget {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 3).allowsHitTesting(false)
                }
            }
            .frame(width: Self.previewWidth, height: Self.previewWidth * 4 / 3)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            .frame(maxWidth: .infinity)
            .dropDestination(for: URL.self) { urls, _ in
                guard let u = urls.first else { return false }
                model.open(url: u)
                return true
            } isTargeted: { dropTarget = $0 }
            .help("Drag or two-finger scroll to move · pinch or ⌘-scroll to zoom · two-finger rotate to tilt · double-click to reset")

            Text("Drag to move · pinch to zoom · rotate to tilt · double-click to reset")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)

            HStack {
                Button("Open photo…") { model.openPanel() }
                Picker("", selection: $editor.mode) {
                    Text("Fill (crop edges)").tag(PhotoParams.Mode.fill)
                    Text("Fit (white border)").tag(PhotoParams.Mode.fit)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                Button { editor.rotate() } label: { Label("Rotate", systemImage: "rotate.right") }
            }

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                AdjustRow(label: "Brightness", value: $editor.brightness)
                AdjustRow(label: "Contrast", value: $editor.contrast)
                AdjustRow(label: "Saturation", value: $editor.saturation)
                GridRow {
                    Text("Tilt")
                    Slider(value: Binding(get: { max(-45, min(45, editor.tilt)) }, set: { editor.tilt = $0 }), in: -45...45)
                    Text(abs(editor.tilt) >= 0.05 ? String(format: "%+.1f°", editor.tilt) : "0°")
                        .monospacedDigit().frame(width: 48, alignment: .trailing)
                }
            }
            HStack {
                Spacer()
                Button("Reset colours") { editor.resetAdjustments() }
                Button("Reset position") { editor.resetPosition() }
            }

            Button {
                confirmPrint = true
            } label: {
                Text(model.printing ? "Printing…" : "Print photo").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(.orange).controlSize(.large)
            .disabled(editor.photo == nil || model.printing)
            .confirmationDialog(model.printQuestion, isPresented: $confirmPrint) {
                Button("Print") { model.printPhoto() }
                Button("Cancel", role: .cancel) {}
            }

            ProgressView(value: model.progress) { Text(model.progressText).font(.caption) }
        }
        .frame(width: Self.previewWidth + 60)
    }
}

struct AdjustRow: View {
    let label: String
    @Binding var value: Double
    var body: some View {
        GridRow {
            Text(label)
            Slider(value: $value, in: -50...50)
            Text(value.rounded() == 0 ? "0" : String(format: "%+.0f", value))
                .monospacedDigit().frame(width: 48, alignment: .trailing)
        }
    }
}
