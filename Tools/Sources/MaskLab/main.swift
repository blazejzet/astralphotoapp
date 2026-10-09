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
for arg in CommandLine.arguments.dropFirst(2) {
    let parts = arg.split(separator: ":").map(String.init)
    let dir = parts[0], frames = Int(parts[1]) ?? 100
    let name = URL(fileURLWithPath: dir).lastPathComponent
    guard let sky = loadTIFF("\(dir)/diag_niebo.tif") ?? loadTIFF("\(dir)/diag_sky.tif"),
          let fg = loadTIFF("\(dir)/diag_ziemia.tif") ?? loadTIFF("\(dir)/diag_ground.tif"),
          let v = loadTIFF("\(dir)/diag_var_niebo_var_ziemia_waga.tif") ?? loadTIFF("\(dir)/diag_skyvar_groundvar_weight.tif") else {
        print("missing diag files in", dir); continue
    }
    let w = sky.width, h = sky.height
    let stack = StackResult(sky: sky, skyWeight: PlanarImage(width: w, height: h, pixels: v.b),
                            skyVariance: PlanarImage(width: w, height: h, pixels: v.r), foreground: fg,
                            foregroundVariance: PlanarImage(width: w, height: h, pixels: v.g), frameCount: frames)
    let fl = fg.luminance
    let sorted = Statistics.sample(fl, stride: 3).sorted()
    print(String(format: "%@: fg luma p0.1 %.4f p1 %.4f median %.4f  (black-level hypothesis: floor ≈ 0.444)", name,
                 sorted[sorted.count / 1000], sorted[sorted.count / 100], sorted[sorted.count / 2]))
    let covered = v.b.filter { $0 > 0 }.count
    print("  sky coverage \(100 * covered / (w * h))%, weight max \(v.b.max() ?? 0)")
    let alpha = SkyMaskBuilder(groundDirection: .down).build(from: stack)
    print(String(format: "  sky fraction new mask %.0f%%", 100 * alpha.pixels.reduce(0, +) / Float(w * h)))
    // Visual: stretched static stack, ground tinted red.
    let stretch = AsinhStretch.automatic(luma: fl, mask: nil, backgroundLevel: 0.2)
    var vis = stretch.apply(fg)
    for i in 0..<(w * h) where alpha.pixels[i] < 0.5 { vis.r[i] = min(1, vis.r[i] * 0.5 + 0.45); vis.g[i] *= 0.5; vis.b[i] *= 0.5 }
    try ImageExport.writeJPEG(vis, to: URL(fileURLWithPath: "\(outDir)/\(name)-masklab.jpg"))
}
