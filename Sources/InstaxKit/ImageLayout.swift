import Foundation

public enum ImageLayout {
    /// 600x800 portrait RGBA (row 0 = top, 4 bytes per pixel, alpha ignored) -> the SP-2 byte layout.
    ///
    /// Same as instax_sp2.image_to_bytes: the portrait is turned 90° clockwise to 800x600, then for each
    /// of the 800 columns (left to right) come 600 red, 600 green and 600 blue bytes (top to bottom).
    /// Column c of the landscape picture is row 799-c of the portrait, read left to right.
    public static func encode(rgba: UnsafeBufferPointer<UInt8>, bytesPerRow: Int = SP2.width * 4) -> [UInt8] {
        precondition(rgba.count >= bytesPerRow * (SP2.height - 1) + SP2.width * 4, "image must be 600x800")
        let w = SP2.width, h = SP2.height
        var out = [UInt8](repeating: 0, count: SP2.imageBytes)
        out.withUnsafeMutableBufferPointer { dst in
            for c in 0..<h {
                let row = rgba.baseAddress! + (h - 1 - c) * bytesPerRow
                let base = c * w * 3
                for y in 0..<w {
                    let px = row + y * 4
                    dst[base + y] = px[0]
                    dst[base + w + y] = px[1]
                    dst[base + 2 * w + y] = px[2]
                }
            }
        }
        return out
    }

    public static func encode(rgba: [UInt8], bytesPerRow: Int = SP2.width * 4) -> [UInt8] {
        rgba.withUnsafeBufferPointer { encode(rgba: $0, bytesPerRow: bytesPerRow) }
    }

    /// Inverse of `encode`, for tests and the fake server: SP-2 bytes -> 600x800 RGBA (opaque).
    public static func decode(_ data: [UInt8]) -> [UInt8] {
        precondition(data.count == SP2.imageBytes)
        let w = SP2.width, h = SP2.height
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        for c in 0..<h {
            let r = (h - 1 - c) * w * 4
            for y in 0..<w {
                rgba[r + y * 4] = data[c * w * 3 + y]
                rgba[r + y * 4 + 1] = data[c * w * 3 + w + y]
                rgba[r + y * 4 + 2] = data[c * w * 3 + 2 * w + y]
            }
        }
        return rgba
    }
}
