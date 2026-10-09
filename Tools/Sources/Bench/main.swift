import AstralCore
import Foundation
import Metal
import QuartzCore
import simd

func time(_ name: String, _ n: Int = 3, _ body: () throws -> Void) rethrows {
    let t0 = CACurrentMediaTime()
    for _ in 0..<n { try body() }
    print(String(format: "%-34@ %8.1f ms", name as NSString, (CACurrentMediaTime() - t0) * 1000 / Double(n)))
}

let device = MTLCreateSystemDefaultDevice()!
let library = try device.makeLibrary(source: String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8), options: nil)
let stacker = try MetalStacker(library: library)
let w = 2016, h = 1512
let k = CameraIntrinsics(fx: 1400, fy: 1400, cx: 1007.5, cy: 755.5, width: w, height: h)
var sky = SyntheticSky.random(intrinsics: k, pole: SIMD3(0.2, -0.8, 0.5), angularRate: Sidereal.angularRate, count: 4000, seed: 1)
sky.horizonY = 1300
var rng = SplitMix64(seed: 2)
let a = sky.render(time: 0, exposure: 1, rng: &rng)
let b = sky.render(time: 1, exposure: 1, rng: &rng)
var raw = [UInt16](repeating: 600, count: 4032 * 3024)
for y in 0..<h { for x in 0..<w {
    let i = y * w + x
    let v = UInt16(min(max(528 + a.g[i] * 15855, 0), 16383))
    raw[2 * y * 4032 + 2 * x] = v; raw[2 * y * 4032 + 2 * x + 1] = v
    raw[(2 * y + 1) * 4032 + 2 * x] = v; raw[(2 * y + 1) * 4032 + 2 * x + 1] = v
} }
let levels = RawLevels(black: SIMD4(repeating: 528), white: 16383)

try time("GPU binBayer (12 MP RAW, incl. copy)") {
    try raw.withUnsafeBytes { try stacker.load(bayer: $0.baseAddress!, rowBytes: 4032 * 2, width: 4032, height: 3024, colorIndex: SIMD4(0, 1, 1, 2), levels: levels) }
}
var luma = PlanarImage(width: 1, height: 1)
time("currentLuma readback") { luma = stacker.currentLuma() }
var stars: [Star] = []
time("StarDetector (3 MP)") { stars = StarDetector().detect(in: luma).stars }
print("  stars:", stars.count)
time("NoiseModelEstimator") { _ = NoiseModelEstimator().estimate(current: a.luminance, previous: b.luminance) }
let engine = AlignmentEngine(intrinsics: k, distortion: nil, priorPole: SIMD3(0.2, -0.8, 0.5))
_ = engine.process(stars: stars, timestamp: 0)
time("AlignmentEngine.process", 10) { _ = engine.process(stars: stars, timestamp: 1) }
time("GPU accumulateSky + foreground", 10) {
    stacker.accumulateForeground()
    stacker.accumulateSky(homography: engine.modelHomography(dt: 1), distortion: nil, noise: NoiseModel(lambdaS: 1e-4, lambdaR: 1e-6),
                          weighting: RobustWeighting(), frameWeight: 1)
}
time("preview (720 px) + stretch + CGImage") {
    let p = stacker.preview(source: .stack, maxDimension: 720, zoom: false)!
    _ = ImageExport.makeCGImage8(AsinhStretch.automatic(luma: p.luminance, mask: nil).apply(p))
}
var result: StackResult?
time("readStack (every 30 frames)", 1) { result = stacker.readStack() }
time("occlusionMask (every 30 frames)", 1) { _ = SkyMaskBuilder().occlusionMask(from: result!, minimumFrames: 1) }
time("Finisher.finish (once, 3 MP)", 1) { _ = Finisher.finish(result!) }
