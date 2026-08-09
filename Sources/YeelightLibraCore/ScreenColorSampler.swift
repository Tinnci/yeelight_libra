import Foundation
import CoreGraphics

/// An sRGB color in 0...255 channel space.
struct RGB: Equatable {
    var r: Int
    var g: Int
    var b: Int

    init(_ r: Int, _ g: Int, _ b: Int) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// Saturation in 0...1 (max-min / max); 0 for grays.
    var saturation: Double {
        let maxC = Double(max(r, g, b))
        let minC = Double(min(r, g, b))
        guard maxC > 0 else { return 0 }
        return (maxC - minC) / maxC
    }
}

/// A raw sampled pixel.
struct RGBPixel: Equatable {
    let r: Int
    let g: Int
    let b: Int
}

/// Samples the main display and extracts the ambient edge color.
/// Actor-isolated so the CoreGraphics grabs never run on the main thread.
final actor ScreenColorSampler {
    static let gridW = 32
    static let gridH = 18

    // MARK: - Authorization

    func authorized() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Prompts for Screen Recording permission; returns whether it is granted.
    func requestAuthorization() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    // MARK: - Capture

    /// Captures the main display, downscales to a small grid, and returns the
    /// tuned ambient edge color. Returns nil when permission is missing, the
    /// display is asleep, or capture fails — callers keep the last color.
    func sampleDisplay() -> RGB? {
        guard authorized(), CGDisplayIsAsleep(CGMainDisplayID()) == 0 else { return nil }
        guard let image = CGDisplayCreateImage(CGMainDisplayID()) else { return nil }

        let w = Self.gridW
        let h = Self.gridH
        let bytesPerRow = w * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * h)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: &buffer, width: w, height: h,
                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                      | CGBitmapInfo.byteOrder32Big.rawValue
              )
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var pixels: [RGBPixel] = []
        pixels.reserveCapacity(w * h)
        for row in 0..<h {
            for col in 0..<w {
                let offset = row * bytesPerRow + col * 4
                pixels.append(RGBPixel(r: Int(buffer[offset]),
                                       g: Int(buffer[offset + 1]),
                                       b: Int(buffer[offset + 2])))
            }
        }
        let edges = Self.edgePixels(of: pixels, gridW: w, gridH: h)
        let average = Self.averageRGB(of: edges, useEdges: false, gridW: w, gridH: h)
        let dominant = Self.dominantRGB(of: edges)
        guard let base = Self.resolveRGB(average: average, dominant: dominant) else { return nil }
        return Self.tuned(base)
    }

    // MARK: - Pure extraction (testable)

    /// The perimeter pixels of a grid (row 0 / last row / col 0 / last col).
    static func edgePixels(of pixels: [RGBPixel], gridW: Int, gridH: Int) -> [RGBPixel] {
        guard pixels.count == gridW * gridH, gridW >= 2, gridH >= 2 else { return [] }
        var result: [RGBPixel] = []
        result.reserveCapacity(2 * (gridW + gridH) - 4)
        for col in 0..<gridW {
            result.append(pixels[col])
            result.append(pixels[(gridH - 1) * gridW + col])
        }
        for row in 1..<(gridH - 1) {
            result.append(pixels[row * gridW])
            result.append(pixels[row * gridW + gridW - 1])
        }
        return result
    }

    /// Average of all pixels, or of the perimeter ring only when `useEdges`.
    static func averageRGB(of pixels: [RGBPixel], useEdges: Bool, gridW: Int, gridH: Int) -> RGB? {
        guard !pixels.isEmpty else { return nil }
        let indices: [Int]
        if useEdges {
            guard pixels.count == gridW * gridH else { return nil }
            indices = (0..<pixels.count).filter { index in
                let row = index / gridW
                let col = index % gridW
                return row == 0 || row == gridH - 1 || col == 0 || col == gridW - 1
            }
        } else {
            indices = Array(0..<pixels.count)
        }
        var sumR = 0, sumG = 0, sumB = 0
        for index in indices {
            sumR += pixels[index].r
            sumG += pixels[index].g
            sumB += pixels[index].b
        }
        let count = indices.count
        return RGB(sumR / count, sumG / count, sumB / count)
    }

    /// Centroid of the largest 4-bit/channel histogram bucket.
    static func dominantRGB(of pixels: [RGBPixel]) -> RGB? {
        guard !pixels.isEmpty else { return nil }
        struct Bucket {
            var count = 0
            var sumR = 0, sumG = 0, sumB = 0
        }
        var buckets: [Int: Bucket] = [:]
        for pixel in pixels {
            let key = ((pixel.r >> 4) << 8) | ((pixel.g >> 4) << 4) | (pixel.b >> 4)
            var bucket = buckets[key] ?? Bucket()
            bucket.count += 1
            bucket.sumR += pixel.r
            bucket.sumG += pixel.g
            bucket.sumB += pixel.b
            buckets[key] = bucket
        }
        guard let best = buckets.max(by: { $0.value.count < $1.value.count })?.value else { return nil }
        return RGB(best.sumR / best.count, best.sumG / best.count, best.sumB / best.count)
    }

    /// Picks the dominant color when the average is washed out (gray-ish).
    static func resolveRGB(average: RGB?, dominant: RGB?) -> RGB? {
        if let average, average.saturation < 0.15,
           let dominant, dominant.saturation > average.saturation {
            return dominant
        }
        return average ?? dominant
    }

    /// Clamp, raise dark colors to a luminance floor (preserving hue), then
    /// boost saturation in HSL space (keeps lightness, so dark stays dark).
    static func tuned(_ rgb: RGB) -> RGB {
        var r = Double(min(max(rgb.r, 0), 255)) / 255.0
        var g = Double(min(max(rgb.g, 0), 255)) / 255.0
        var b = Double(min(max(rgb.b, 0), 255)) / 255.0

        let floor: Double = 6.0 / 255.0
        let maxC = max(r, g, b)
        if maxC > 0 && maxC < floor {
            let scale = floor / maxC
            r *= scale
            g *= scale
            b *= scale
        }

        let (h, s, l) = rgbToHSL(r, g, b)
        let (nr, ng, nb) = hslToRGB(h, min(s * 1.2, 1.0), l)
        return RGB(
            min(max(Int((nr * 255).rounded()), 0), 255),
            min(max(Int((ng * 255).rounded()), 0), 255),
            min(max(Int((nb * 255).rounded()), 0), 255))
    }

    /// Per-channel delta hysteresis: skip sends when the color barely moved.
    static func shouldSend(current: RGB?, next: RGB, threshold: Int = 8) -> Bool {
        guard let current else { return true }
        return abs(current.r - next.r) >= threshold
            || abs(current.g - next.g) >= threshold
            || abs(current.b - next.b) >= threshold
    }

    // MARK: - HSL helpers

    private static func rgbToHSL(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, l: Double) {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC
        let l = (maxC + minC) / 2
        guard delta > 0 else { return (0, 0, l) }
        let s = delta / (1 - abs(2 * l - 1))
        var h: Double
        if maxC == r {
            h = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6))
        } else if maxC == g {
            h = 60 * ((b - r) / delta + 2)
        } else {
            h = 60 * ((r - g) / delta + 4)
        }
        if h < 0 { h += 360 }
        return (h, s, l)
    }

    private static func hueToRGB(_ p: Double, _ q: Double, _ t: Double) -> Double {
        var t = t
        if t < 0 { t += 1 }
        if t > 1 { t -= 1 }
        if t < 1.0 / 6.0 { return p + (q - p) * 6 * t }
        if t < 1.0 / 2.0 { return q }
        if t < 2.0 / 3.0 { return p + (q - p) * (2.0 / 3.0 - t) * 6 }
        return p
    }

    private static func hslToRGB(_ h: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
        if s == 0 { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        let hn = h / 360
        return (hueToRGB(p, q, hn + 1.0 / 3.0),
                hueToRGB(p, q, hn),
                hueToRGB(p, q, hn - 1.0 / 3.0))
    }
}
