// StaxPrint (Swift) — print photos to a Fujifilm Instax SHARE SP-2 over Wi-Fi.
// "Instax" and "SHARE SP-2" are trademarks of FUJIFILM, used only to describe compatibility.

import AppKit
import SwiftUI

/// Logo images. In the .app they sit in Contents/Resources; under `swift run` they come from SwiftPM's bundle.
enum Brand {
    static func image(_ name: String) -> NSImage? {
        if let url = Bundle.main.url(forResource: name, withExtension: "png") { return NSImage(contentsOf: url) }
        return Bundle.module.url(forResource: name, withExtension: "png").flatMap(NSImage.init(contentsOf:))
    }
    static let mark = image("staxprint-mark")
    static let icon = image("staxprint-icon")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when run as a bare executable (swift run) rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        if Bundle.main.bundleURL.pathExtension != "app", let icon = Brand.icon { NSApp.applicationIconImage = icon }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct StaxPrintApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("StaxPrint", id: "main") {
            ContentView(model: model)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Photo…") { model.openPanel() }.keyboardShortcut("o")
            }
        }
    }
}
