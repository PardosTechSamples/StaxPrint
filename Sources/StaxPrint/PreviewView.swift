import AppKit
import CoreImage
import InstaxKit
import MetalKit
import Observation
import SwiftUI

/// The 600x800 print frame, drawn by Core Image straight into a Metal drawable, only when something changes.
/// Trackpad: two-finger scroll moves, pinch zooms, two-finger rotate tilts. Mouse: drag moves,
/// ⌘-scroll (or a plain wheel) zooms. Double-click resets.
final class PreviewMTKView: MTKView {
    let editor: PhotoEditor
    private let renderer = PhotoRenderer.shared
    private let queue: MTLCommandQueue?
    private let background = CIImage(color: CIColor(red: 0.02, green: 0.03, blue: 0.06))
    private var lastDrag: NSPoint?
    var onFrame: ((Double) -> Void)?

    @MainActor
    init(editor: PhotoEditor) {
        self.editor = editor
        queue = renderer.device?.makeCommandQueue()
        super.init(frame: .zero, device: renderer.device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = false               // Core Image writes into the drawable's texture
        isPaused = true                       // draw on demand only
        enableSetNeedsDisplay = true
        autoResizeDrawable = true
        (layer as? CAMetalLayer)?.colorspace = renderer.srgb
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        track()
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Redraw whenever anything the picture depends on changes.
    @MainActor private func track() {
        withObservationTracking {
            _ = editor.photo?.width
            _ = editor.params
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.needsDisplay = true
                self.track()
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let queue, let drawable = currentDrawable, let cb = queue.makeCommandBuffer() else { return }
        let t0 = CACurrentMediaTime()
        let size = drawableSize
        let image: CIImage
        if let photo = MainActor.assumeIsolated({ editor.photo }) {
            let params = MainActor.assumeIsolated { editor.params }
            image = renderer.compose(photo, params, outWidth: size.width, outHeight: size.height)
        } else {
            image = background.cropped(to: CGRect(origin: .zero, size: size))
        }
        let dest = CIRenderDestination(width: Int(size.width), height: Int(size.height), pixelFormat: colorPixelFormat,
                                       commandBuffer: cb) { drawable.texture }
        dest.colorSpace = renderer.srgb
        _ = try? renderer.context.startTask(toRender: image, to: dest)
        cb.present(drawable)
        cb.commit()
        onFrame?(CACurrentMediaTime() - t0)
    }

    // MARK: input

    /// Print pixels per view point.
    private var unit: Double { Double(SP2.width) / max(1, bounds.width) }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: lastDrag == nil ? .openHand : .closedHand) }

    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 { MainActor.assumeIsolated { editor.resetPosition() }; return }
        lastDrag = e.locationInWindow
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with e: NSEvent) {
        guard let last = lastDrag else { return }
        let p = e.locationInWindow
        lastDrag = p
        let u = unit
        MainActor.assumeIsolated { editor.move(by: (p.x - last.x) * u, -(p.y - last.y) * u) }
    }

    override func mouseUp(with e: NSEvent) {
        lastDrag = nil
        NSCursor.openHand.set()
    }

    override func scrollWheel(with e: NSEvent) {
        let zoomKey = !e.modifierFlags.intersection([.command, .control]).isEmpty
        let u = unit
        MainActor.assumeIsolated {
            if e.hasPreciseScrollingDeltas && !zoomKey {          // trackpad two-finger scroll: move
                editor.move(by: e.scrollingDeltaX * u, e.scrollingDeltaY * u)
            } else if e.hasPreciseScrollingDeltas {               // ⌘ + trackpad scroll: smooth zoom
                editor.zoom(by: pow(1.01, e.scrollingDeltaY))
            } else {                                              // mouse wheel: zoom
                editor.zoom(by: pow(1.1, e.scrollingDeltaY))
            }
        }
    }

    override func magnify(with e: NSEvent) {
        MainActor.assumeIsolated { editor.zoom(by: 1 + e.magnification) }
    }

    override func rotate(with e: NSEvent) {
        // AppKit reports counter-clockwise finger rotation as positive; tilt is positive clockwise.
        MainActor.assumeIsolated { editor.tilt(by: -Double(e.rotation)) }
    }

    override func smartMagnify(with e: NSEvent) {
        MainActor.assumeIsolated { editor.resetPosition() }
    }
}

struct PreviewView: NSViewRepresentable {
    let editor: PhotoEditor
    var onFrame: ((Double) -> Void)?

    func makeNSView(context: Context) -> PreviewMTKView {
        let v = PreviewMTKView(editor: editor)
        v.onFrame = onFrame
        return v
    }

    func updateNSView(_ v: PreviewMTKView, context: Context) {}
}
