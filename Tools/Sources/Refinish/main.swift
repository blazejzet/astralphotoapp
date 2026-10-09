import AstralCore
import CoreGraphics
import Foundation
import ImageIO

/// Loads a linear float TIFF written by the app into an RGBImage.
func loadTIFF(_ path: String) -> RGBImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let w = img.width, h = img.height
    var buf = [Float](repeating: 0, count: w * h * 4)
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 16,
                              space: CGColorSpace(name: CGColorSpace.linearSRGB)!, bitmapInfo: info.rawValue) else { return nil }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    var out = RGBImage(width: w, height: h)
    for i in 0..<(w * h) { out.r[i] = buf[4 * i]; out.g[i] = buf[4 * i + 1]; out.b[i] = buf[4 * i + 2] }
    return out
}

/// Re-runs the Finisher on the diag_* stacks of a session, as the app would at "Finish and save".
let outDir = CommandLine.arguments[1]
for dir in CommandLine.arguments.dropFirst(2) {
    let name = URL(fileURLWithPath: dir).lastPathComponent
    guard let sky = loadTIFF("\(dir)/diag_sky.tif"), let fg = loadTIFF("\(dir)/diag_ground.tif"),
          let v = loadTIFF("\(dir)/diag_skyvar_groundvar_weight.tif"),
          let log = try? String(contentsOfFile: "\(dir)/session.txt", encoding: .utf8) else {
        print("missing diag files in", dir); continue
    }
    func number(after prefix: String) -> Double? {
        guard let range = log.range(of: prefix) else { return nil }
        return Double(log[range.upperBound...].prefix { "0123456789.".contains($0) })
    }
    let orientation = UInt32(number(after: "EXIF orientation ") ?? 1)
    let frames = Int(number(after: "Frames: ") ?? 100)
    let w = sky.width, h = sky.height
    var stack = StackResult(sky: sky, skyWeight: PlanarImage(width: w, height: h, pixels: v.b),
                            skyVariance: PlanarImage(width: w, height: h, pixels: v.r), foreground: fg,
                            foregroundVariance: PlanarImage(width: w, height: h, pixels: v.g), frameCount: frames)
    if let plain = loadTIFF("\(dir)/diag_skyplain_mean_var.tif") {
        stack.skyPlainMean = PlanarImage(width: w, height: h, pixels: plain.r.map { $0 < 0 ? .nan : $0 })
        stack.skyPlainVariance = PlanarImage(width: w, height: h, pixels: plain.g.map { $0 < 0 ? .nan : $0 })
    }
    var options = FinishingOptions()
    options.groundDirection = ImageDirection(exifOrientation: orientation)
    options.skyDrift = number(after: "Sky drift: max ")
    // The app's own mask (built with the capture-time ground prior, which is not saved).
    if let mask = loadTIFF("\(dir)/mask.png"), mask.width == w, mask.height == h {
        options.skyMask = PlanarImage(width: w, height: h, pixels: mask.g)
    }
    let finished = Finisher.finish(stack, options: options)
    print("\(name):")
    for note in finished.notes { print("  " + note) }
    try ImageExport.writeJPEG(finished.display, to: URL(fileURLWithPath: "\(outDir)/\(name)-refinish.jpg"), orientation: orientation)
}
