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

func loadMask(_ path: String, width: Int, height: Int) -> PlanarImage {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil), img.width == width, img.height == height else {
        return PlanarImage(width: width, height: height, repeating: 1)
    }
    var buf = [UInt8](repeating: 0, count: width * height)
    let ctx = CGContext(data: &buf, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
    return PlanarImage(width: width, height: height, pixels: buf.map { $0 >= 230 ? 1 : 0 })
}

let outDir = CommandLine.arguments[1]
/// args: outDir then pairs "<session dir>:<name>[:x,y,w,h crop]"
for arg in CommandLine.arguments.dropFirst(2) {
    let parts = arg.split(separator: ":").map(String.init)
    let dir = parts[0], name = parts[1]
    guard var img = loadTIFF("\(dir)/astral_linear.tif") else { print("cannot load", dir); continue }
    let mask = loadMask("\(dir)/maska.png", width: img.width, height: img.height)
    var notes: [String] = []
    if let model = VignettingCorrection.fit(img, mask: mask) {
        VignettingCorrection.apply(model, to: &img)
        notes.append(String(format: "vignette corner G %.2f", model.cornerFalloff(channel: 1)))
    }
    // Two passes: the second catches what the first leaves after outlier cells were rejected.
    GradientRemoval.apply(&img, mask: mask)
    GradientRemoval.apply(&img, mask: mask)
    let luma = img.luminance
    let (bg, noise) = Statistics.backgroundAndNoise(luma, mask: mask)
    // Flatness: spread of 8×6 cell medians relative to background noise.
    var cells: [Float] = []
    for gy in 0..<6 { for gx in 0..<8 {
        var v: [Float] = []
        for y in stride(from: gy * img.height / 6, to: (gy + 1) * img.height / 6, by: 4) {
            for x in stride(from: gx * img.width / 8, to: (gx + 1) * img.width / 8, by: 4) { v.append(luma[x, y]) }
        }
        cells.append(Statistics.sigmaClipped(v, kappa: 2).median)
    } }
    let spread = (cells.max()! - cells.min()!) / max(bg, 1e-6)
    print(String(format: "%@: bg %.4f noise %.5f cell spread %.1f%% of bg  %@", name, bg, noise, spread * 100, notes.joined(separator: ", ")))
    let stretch = AsinhStretch.automatic(luma: luma, mask: nil, backgroundLevel: 0.11)
    let display = stretch.apply(img)
    try ImageExport.writeJPEG(display, to: URL(fileURLWithPath: "\(outDir)/\(name).jpg"), quality: 0.86)
    if parts.count > 2 {
        let c = parts[2].split(separator: ",").compactMap { Int($0) }
        var crop = RGBImage(width: c[2], height: c[3])
        for y in 0..<c[3] { for x in 0..<c[2] {
            let i = (c[1] + y) * img.width + c[0] + x, j = y * c[2] + x
            crop.r[j] = display.r[i]; crop.g[j] = display.g[i]; crop.b[j] = display.b[i]
        } }
        try ImageExport.writeJPEG(crop, to: URL(fileURLWithPath: "\(outDir)/\(name)-crop.jpg"), quality: 0.9)
    }
}
