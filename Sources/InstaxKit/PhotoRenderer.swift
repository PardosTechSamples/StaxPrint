import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Metal

/// How the photo sits in the 600x800 frame. Zoom 1 = the photo just fills / fits the frame; dx/dy are in
/// print pixels (y down); tilt is in degrees, positive = clockwise; rotation is a multiple of 90 (clockwise).
public struct PhotoParams: Equatable, Sendable {
    public enum Mode: String, CaseIterable, Sendable { case fill, fit }
    public var mode: Mode = .fill
    public var rotation = 0
    public var zoom = 1.0
    public var dx = 0.0
    public var dy = 0.0
    public var tilt = 0.0
    public var brightness = 0.0   // -50...50
    public var contrast = 0.0     // -50...50
    public var saturation = 0.0   // -50...50
    public init() {}
}

public struct LoadedPhoto: @unchecked Sendable {
    public let image: CIImage          // upright, sRGB, origin (0,0)
    /// image, then pre-baked halves of it (down to ~256 px), so each frame only ever downsamples by ≤ 2x.
    public let levels: [CIImage]
    public let width: Int
    public let height: Int
    public let note: String
}

public final class PhotoRenderer: @unchecked Sendable {
    public static let shared = PhotoRenderer()

    public let device: MTLDevice?
    public let context: CIContext
    public let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    public init() {
        device = MTLCreateSystemDefaultDevice()
        let opts: [CIContextOption: Any] = [.cacheIntermediates: true, .name: "StaxPrint"]
        context = device.map { CIContext(mtlDevice: $0, options: opts) } ?? CIContext(options: opts)
    }

    // MARK: loading

    /// Opens any image ImageIO can read (JPEG, PNG, HEIC, TIFF, …) upright, colour-managed into sRGB and no
    /// bigger than needed. HDR images (PQ / HLG, gain maps) are tone-mapped to SDR first, so an iPhone HDR
    /// PNG tagged "Display P3 PQ" doesn't come out washed out.
    public func load(url: URL, maxSide: Int = 2400) throws -> LoadedPhoto {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            throw InstaxError("Could not read \(url.lastPathComponent) as an image.")
        }
        let profile = (props[kCGImagePropertyProfileName] as? String) ?? "no colour profile (treated as sRGB)"
        guard var img = CIImage(contentsOf: url, options: [.applyOrientationProperty: true, .toneMapHDRtoSDR: true]) else {
            throw InstaxError("Could not decode \(url.lastPathComponent).")
        }
        img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        let side = max(img.extent.width, img.extent.height)
        if side > CGFloat(maxSide) {
            img = img.applyingFilter("CILanczosScaleTransform",
                                     parameters: [kCIInputScaleKey: CGFloat(maxSide) / side, kCIInputAspectRatioKey: 1.0])
        }
        let rect = CGRect(x: 0, y: 0, width: img.extent.width.rounded(.down), height: img.extent.height.rounded(.down))
        // Bake it once into an 8-bit sRGB bitmap: every later frame starts from this.
        guard let cg = context.createCGImage(img, from: rect, format: .RGBA8, colorSpace: srgb) else {
            throw InstaxError("Could not convert \(url.lastPathComponent) to sRGB.")
        }
        let hdr = (props[kCGImagePropertyPNGDictionary] != nil && profile.contains("PQ")) || profile.contains("HLG")
        let note = profile.hasPrefix("no colour") ? profile
            : "converted \(profile)\(hdr ? " (HDR, tone-mapped)" : "") → sRGB"
        var levels = [CIImage(cgImage: cg)]
        while let last = levels.last, max(last.extent.width, last.extent.height) > 512 {
            let half = last.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 0.5, kCIInputAspectRatioKey: 1.0])
            let r = CGRect(x: 0, y: 0, width: half.extent.width.rounded(.down), height: half.extent.height.rounded(.down))
            guard let c = context.createCGImage(half, from: r, format: .RGBA8, colorSpace: srgb) else { break }
            levels.append(CIImage(cgImage: c))
        }
        levels = levels.map(gpuResident)
        return LoadedPhoto(image: levels[0], levels: levels, width: cg.width, height: cg.height, note: note)
    }

    /// Copies an image into a Metal texture once, so frames don't re-upload the bitmap to the GPU.
    func gpuResident(_ img: CIImage) -> CIImage {
        guard let device, let queue = device.makeCommandQueue(), let cb = queue.makeCommandBuffer() else { return img }
        let w = Int(img.extent.width), h = Int(img.extent.height)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        desc.storageMode = .private
        guard let tex = device.makeTexture(descriptor: desc) else { return img }
        context.render(img, to: tex, commandBuffer: cb, bounds: img.extent, colorSpace: srgb)
        cb.commit()
        cb.waitUntilCompleted()
        // Core Image reads the texture back in the same orientation it wrote it.
        return CIImage(mtlTexture: tex, options: [.colorSpace: srgb]) ?? img
    }

    // MARK: composing

    /// The picture as printed, `outWidth` x `outHeight` pixels (600x800, or a screen-sized version of it),
    /// origin (0,0), on white. Preview and print both come from here, so they always match.
    public func compose(_ photo: CIImage, _ p: PhotoParams, outWidth: CGFloat, outHeight: CGFloat) -> CIImage {
        compose(levels: [photo], p, outWidth: outWidth, outHeight: outHeight)
    }

    public func compose(_ photo: LoadedPhoto, _ p: PhotoParams, outWidth: CGFloat, outHeight: CGFloat) -> CIImage {
        compose(levels: photo.levels, p, outWidth: outWidth, outHeight: outHeight)
    }

    /// `levels`: the photo at full size, then successively halved copies of it.
    public func compose(levels: [CIImage], _ p: PhotoParams, outWidth: CGFloat, outHeight: CGFloat) -> CIImage {
        let photo = levels[0]
        let out = CGRect(x: 0, y: 0, width: outWidth, height: outHeight)
        let unit = outWidth / CGFloat(SP2.width)                 // output pixels per print pixel
        let quarter = ((p.rotation % 360) + 360) % 360 / 90
        let w = photo.extent.width, h = photo.extent.height
        let (rw, rh) = quarter % 2 == 1 ? (h, w) : (w, h)
        let fx = CGFloat(SP2.width) / rw, fy = CGFloat(SP2.height) / rh
        let base = p.mode == .fill ? max(fx, fy) : min(fx, fy)
        var k = base * p.zoom * unit                             // output pixels per full-size source pixel

        // Start from the smallest pre-baked level that is still at least as big as needed.
        var level = 0
        while level + 1 < levels.count, levels[level + 1].extent.width / w >= k { level += 1 }
        var src = levels[level]
        var srcW = src.extent.width, srcH = src.extent.height
        k *= w / srcW                                            // output pixels per level pixel

        // Colour adjustments on the photo only, so a white border stays white.
        src = src.applyingFilter("CIColorControls", parameters: [
            kCIInputBrightnessKey: p.brightness / 200,
            kCIInputContrastKey: 1 + p.contrast / 100,
            kCIInputSaturationKey: 1 + p.saturation / 100,
        ])
        // High-quality downscale (≤ 2x from the chosen level); the affine below then only rotates, moves
        // and, when zoomed in, enlarges.
        if k < 0.999 {
            src = src.clampedToExtent()
                .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: k, kCIInputAspectRatioKey: 1.0])
                .cropped(to: CGRect(x: 0, y: 0, width: srcW * k, height: srcH * k))
            srcW *= k; srcH *= k
            k = 1
        }
        // Core Image is y-up: a clockwise turn on screen is a negative angle, and dy (down) is -y.
        let angle = -(Double(quarter) * 90 + p.tilt) * .pi / 180
        let cx = outWidth / 2 + p.dx * unit, cy = outHeight / 2 - p.dy * unit
        let t = CGAffineTransform(translationX: -srcW / 2, y: -srcH / 2)
            .concatenating(CGAffineTransform(scaleX: k, y: k))
            .concatenating(CGAffineTransform(rotationAngle: angle))
            .concatenating(CGAffineTransform(translationX: cx, y: cy))
        let img = src.transformed(by: t, highQualityDownsample: false)
        return img.composited(over: CIImage(color: .white).cropped(to: out)).cropped(to: out)
    }

    // MARK: print output

    /// Renders the 600x800 print as RGBA8 sRGB, row 0 = top.
    public func renderPrintRGBA(_ photo: CIImage, _ p: PhotoParams) -> [UInt8] {
        renderPrintRGBA(levels: [photo], p)
    }

    public func renderPrintRGBA(_ photo: LoadedPhoto, _ p: PhotoParams) -> [UInt8] {
        renderPrintRGBA(levels: photo.levels, p)
    }

    public func renderPrintRGBA(levels: [CIImage], _ p: PhotoParams) -> [UInt8] {
        let img = compose(levels: levels, p, outWidth: CGFloat(SP2.width), outHeight: CGFloat(SP2.height))
        let rect = CGRect(x: 0, y: 0, width: SP2.width, height: SP2.height)
        var buf = [UInt8](repeating: 255, count: SP2.width * SP2.height * 4)
        // CIContext.render(toBitmap:) writes the top row first, like a CGImage.
        context.render(img, toBitmap: &buf, rowBytes: SP2.width * 4, bounds: rect, format: .RGBA8, colorSpace: srgb)
        return buf
    }

    public func cgImage(rgba: [UInt8], width: Int = SP2.width, height: Int = SP2.height) -> CGImage? {
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: srgb, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    public func writePNG(_ cg: CGImage, to url: URL) throws {
        guard let dst = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw InstaxError("Cannot write \(url.path)")
        }
        CGImageDestinationAddImage(dst, cg, nil)
        guard CGImageDestinationFinalize(dst) else { throw InstaxError("Cannot write \(url.path)") }
    }
}
