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

let outDir = CommandLine.arguments[1]
for path in CommandLine.arguments.dropFirst(2) {
    guard let img = loadTIFF(path) else { print("cannot load", path); continue }
    let name = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
    let luma = img.luminance
    let (bg, noise) = Statistics.backgroundAndNoise(luma)
    let det = StarDetector().detect(in: luma)
    let s = det.stars
    let p999 = Statistics.percentile(Statistics.sample(luma, stride: 2), 0.999)
    let maxV = luma.pixels.max() ?? 0
    // Column/row profile of the dead margin
    var colMeans: [Float] = []
    for x in stride(from: img.width - 120, to: img.width, by: 8) {
        var sum: Float = 0; for y in 0..<img.height { sum += luma[x, y] }; colMeans.append(sum / Float(img.height))
    }
    print("== \(name)  \(img.width)×\(img.height)")
    print(String(format: "  bg %.5f  noise %.6f  p99.9 %.4f  max %.3f  stars %d", bg, noise, p999, maxV, s.count))
    let top = s.prefix(10).map { String(format: "(%.0f,%.0f pk %.4f fwhm %.1f)", $0.position.x, $0.position.y, $0.peak, $0.fwhm) }
    print("  top:", top.joined(separator: " "))
    print("  peak S/N of top 20:", s.prefix(20).map { Int($0.peak / max(det.noise, 1e-9)) })
    print("  right-margin column means:", colMeans.map { String(format: "%.4f", $0) }.joined(separator: " "))
    // Alternative renders: auto stretch whole frame + 1:1 centre crop.
    let stretch = AsinhStretch.automatic(luma: luma, mask: nil, backgroundLevel: 0.15)
    print(String(format: "  stretch black %.5f beta %.6f white %.4f", stretch.black, stretch.beta, stretch.white))
    try ImageExport.writeJPEG(stretch.apply(img), to: URL(fileURLWithPath: "\(outDir)/\(name)_restretch.jpg"))
    let cw = 600, ch = 450, x0 = (img.width - cw) / 2, y0 = (img.height - ch) / 2
    var crop = RGBImage(width: cw, height: ch)
    for y in 0..<ch { for x in 0..<cw { let i = (y0 + y) * img.width + x0 + x, j = y * cw + x
        crop.r[j] = img.r[i]; crop.g[j] = img.g[i]; crop.b[j] = img.b[i] } }
    try ImageExport.writeJPEG(stretch.apply(crop), to: URL(fileURLWithPath: "\(outDir)/\(name)_crop.jpg"))
}
