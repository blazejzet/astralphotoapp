import AstralCore
import Foundation
import Metal
import simd

func report(_ name: String, _ ok: Bool, _ detail: String) {
    print("\(ok ? "PASS" : "FAIL")  \(name): \(detail)")
    if !ok { failures += 1 }
}
nonisolated(unsafe) var failures = 0

let shaderPath = CommandLine.arguments[1]
let outDir = CommandLine.arguments[2]
let device = MTLCreateSystemDefaultDevice()!
let library = try device.makeLibrary(source: String(contentsOfFile: shaderPath, encoding: .utf8), options: nil)
let stacker = try MetalStacker(library: library)

let w = 320, h = 240, rawW = 640, rawH = 480
let black: Float = 528, white: Float = 16383
let k = CameraIntrinsics(fx: 300, fy: 300, cx: 159.5, cy: 119.5, width: w, height: h)
let omega = Sidereal.angularRate * 120
let truePole = simd_normalize(SIMD3<Double>(0.25, -0.85, 0.45))
var sky = SyntheticSky.random(intrinsics: k, pole: truePole, angularRate: omega, count: 900, seed: 42)
sky.horizonY = 190
sky.groundLights = [(SIMD2(60, 210), 2.0), (SIMD2(250, 220), 3.0)]

/// RGGB mosaic: each binned RGB pixel → 2×2 raw samples (G duplicated), plus one hot pixel.
func mosaic(_ img: RGBImage, hotPixel: Bool = true, darkOffset: Float = 0) -> [UInt16] {
    var raw = [UInt16](repeating: 0, count: rawW * rawH)
    func q(_ v: Float) -> UInt16 { UInt16(min(max(black + (v + darkOffset) * (white - black), 0), white).rounded()) }
    for y in 0..<h {
        for x in 0..<w {
            let i = y * w + x
            raw[(2 * y) * rawW + 2 * x] = q(img.r[i])
            raw[(2 * y) * rawW + 2 * x + 1] = q(img.g[i])
            raw[(2 * y + 1) * rawW + 2 * x] = q(img.g[i])
            raw[(2 * y + 1) * rawW + 2 * x + 1] = q(img.b[i])
        }
    }
    if hotPixel { raw[77 * rawW + 101] = UInt16(white) }
    return raw
}

func load(_ raw: [UInt16]) throws {
    try raw.withUnsafeBytes { buf in
        try stacker.load(bayer: buf.baseAddress!, rowBytes: rawW * 2, width: rawW, height: rawH,
                         colorIndex: SIMD4(0, 1, 1, 2), levels: RawLevels(black: SIMD4(repeating: black), white: white))
    }
}

// 1. Binning, normalisation, hot-pixel filter.
var rng = SplitMix64(seed: 99)
let first = sky.render(time: 0, exposure: 0.15, rng: &rng)
try load(mosaic(first))
let gpuFrame = stacker.currentFrame()
var maxErr: Float = 0
for y in 0..<h { for x in 0..<w where !(x == 50 && y == 38) {
    let i = y * w + x
    maxErr = max(maxErr, abs(gpuFrame.r[i] - first.r[i]), abs(gpuFrame.g[i] - first.g[i]), abs(gpuFrame.b[i] - first.b[i]))
} }
report("binBayer", maxErr < 2e-4, "max |GPU − truth| = \(maxErr)")
let hotValue = gpuFrame.g[38 * w + 50]
report("hot pixel filter", abs(hotValue - first.g[38 * w + 50]) < 0.02, "G at hot site = \(hotValue) (truth \(first.g[38 * w + 50]))")
let luma = stacker.currentLuma()
report("luma", abs(luma[10, 10] - first.luminance[10, 10]) < 2e-4, "\(luma[10, 10]) vs \(first.luminance[10, 10])")

// 1b. Active-area crop (iPhone 17 Pro buffers carry dead margin columns).
func padded(_ img: RGBImage, originX: Int, originY: Int, padW: Int, padH: Int) -> ([UInt16], Int, Int) {
    let bw = rawW + padW, bh = rawH + padH
    var buf = [UInt16](repeating: 0, count: bw * bh)
    for y in 0..<rawH { for x in 0..<rawW {
        let ax = x + originX, ay = y + originY
        // Absolute RGGB parity, each absolute 2×2 quad carries one binned value of `img` (clamped).
        let bx = min(max((ax - originX) / 2, 0), w - 1), by = min(max((ay - originY) / 2, 0), h - 1)
        let i = by * w + bx
        let v: Float = (ay & 1) == 0 ? ((ax & 1) == 0 ? img.r[i] : img.g[i]) : ((ax & 1) == 0 ? img.g[i] : img.b[i])
        buf[ay * bw + ax] = UInt16(min(max(black + v * (white - black), 0), white).rounded())
    } }
    return (buf, bw, bh)
}
do {
    let (buf, bw, bh) = padded(first, originX: 4, originY: 2, padW: 40, padH: 6)
    try buf.withUnsafeBytes {
        try stacker.load(bayer: $0.baseAddress!, rowBytes: bw * 2, width: bw, height: bh, colorIndex: SIMD4(0, 1, 1, 2),
                         levels: RawLevels(black: SIMD4(repeating: black), white: white, crop: RawCrop(x: 4, y: 2, width: rawW, height: rawH)))
    }
    let f = stacker.currentFrame()
    var err: Float = 0
    for i in 0..<(w * h) { err = max(err, abs(f.r[i] - first.r[i]), abs(f.g[i] - first.g[i]), abs(f.b[i] - first.b[i])) }
    report("crop (even origin, dead margin)", f.width == w && f.height == h && err < 2e-4, "\(f.width)×\(f.height), max err \(err)")

    let flat = RGBImage(width: w, height: h, r: .init(repeating: 0.1, count: w * h), g: .init(repeating: 0.2, count: w * h), b: .init(repeating: 0.3, count: w * h))
    let (buf2, bw2, bh2) = padded(flat, originX: 3, originY: 1, padW: 40, padH: 6)
    try buf2.withUnsafeBytes {
        try stacker.load(bayer: $0.baseAddress!, rowBytes: bw2 * 2, width: bw2, height: bh2, colorIndex: SIMD4(0, 1, 1, 2),
                         levels: RawLevels(black: SIMD4(repeating: black), white: white, crop: RawCrop(x: 3, y: 1, width: rawW, height: rawH)))
    }
    let g = stacker.currentFrame()
    let c = SIMD3(g.r[5000], g.g[5000], g.b[5000])
    report("crop (odd origin, CFA parity)", simd_length(c - SIMD3(0.1, 0.2, 0.3)) < 1e-3, "rgb = \(c)")
}

// 2. Full stacking: GPU vs the tested CPU reference on identical binned frames and warps.
var config = AlignmentEngine.Configuration()
config.angularRate = omega
config.minBaselineForFit = 4
config.refitEvery = 5
let engine = AlignmentEngine(intrinsics: k, distortion: nil, priorPole: nil, configuration: config)
var dc = StarDetector.Configuration(); dc.meshSize = 32; dc.maxStars = 80
let detector = StarDetector(configuration: dc)
let cpu = CPUStacker(width: w, height: h)
stacker.resetStack()
rng = SplitMix64(seed: 99)
let noise = NoiseModel(lambdaS: 3.75e-6, lambdaR: 1.5e-6)
var accepted = 0
var occlusion: PlanarImage?
for f in 0..<40 {
    let t = Double(f)
    let frame = sky.render(time: t, exposure: 0.15, rng: &rng, satellite: f == 25 ? (SIMD2(0, 30), SIMD2(319, 150)) : nil)
    try load(mosaic(frame))
    let binned = stacker.currentFrame()
    let alignment = engine.process(stars: detector.detect(in: stacker.currentLuma()).stars, timestamp: t + 0.075)
    guard alignment.accepted else { continue }
    accepted += 1
    if accepted % 10 == 0 {
        occlusion = SkyMaskBuilder().occlusionMask(from: cpu.result())
        stacker.setOcclusion(occlusion)
    }
    stacker.accumulateForeground()
    stacker.accumulateSky(homography: alignment.homography, distortion: nil, noise: noise, weighting: RobustWeighting(), frameWeight: 1)
    cpu.add(frame: binned, mapper: WarpMapper(homography: alignment.homography, distortion: nil), noise: noise, occlusion: occlusion)
}
report("alignment", accepted >= 36 && engine.poleFitted, "accepted \(accepted)/40, pole error \(acos(simd_dot(engine.pole!, truePole)) * 180 / .pi)°")

let gpu = stacker.readStack()!
let ref = cpu.result()
var skyDiff: [Float] = [], weightDiff: [Float] = [], fgDiff: [Float] = []
for i in 0..<(w * h) {
    if gpu.skyWeight.pixels[i] > 0 && ref.skyWeight.pixels[i] > 0 {
        skyDiff.append(abs(gpu.sky.g[i] - ref.sky.g[i]))
        weightDiff.append(abs(gpu.skyWeight.pixels[i] - ref.skyWeight.pixels[i]))
    }
    fgDiff.append(abs(gpu.foreground.r[i] - ref.foreground.r[i]))
}
skyDiff.sort(); weightDiff.sort(); fgDiff.sort()
let p999 = { (a: [Float]) in a[min(a.count - 1, Int(Double(a.count) * 0.999))] }
report("sky stack GPU≈CPU", p999(skyDiff) < 2e-3, "median \(skyDiff[skyDiff.count / 2]), p99.9 \(p999(skyDiff)), max \(skyDiff.last!)")
let flipped = Float(weightDiff.filter { $0 > 0.5 }.count) / Float(weightDiff.count)
report("weights GPU≈CPU", weightDiff[weightDiff.count / 2] < 1e-3 && flipped < 0.005,
       "median \(weightDiff[weightDiff.count / 2]), pixels with a flipped accept/reject decision: \(flipped * 100)%")
report("foreground GPU≈CPU", fgDiff.last! < 1e-5, "max \(fgDiff.last!)")
var plainDiff: Float = 0, plainCount = 0
if let gm = gpu.skyPlainMean, let cm = ref.skyPlainMean, let gv = gpu.skyPlainVariance, let cv = ref.skyPlainVariance {
    for i in 0..<(w * h) where gm.pixels[i].isFinite && cm.pixels[i].isFinite {
        plainDiff = max(plainDiff, abs(gm.pixels[i] - cm.pixels[i]), abs(gv.pixels[i] - cv.pixels[i]) * 100)
        plainCount += 1
    }
}
report("unweighted sky stats GPU≈CPU", plainCount > w * h / 2 && plainDiff < 2e-4, "pixels \(plainCount), max diff \(plainDiff)")
report("frame count", gpu.frameCount == ref.frameCount, "\(gpu.frameCount) vs \(ref.frameCount)")

let clean = sky.render(time: 0, exposure: 0.15, rng: &rng, addNoise: false).luminance
let trailErr = abs(gpu.sky.luminance[160, 90] - clean[160, 90])
report("satellite rejected (GPU)", trailErr < 0.01, "|stack − truth| on trail = \(trailErr)")

// 3. Preview and finishing on the GPU result.
let prev = stacker.preview(source: .stack, maxDimension: 160, zoom: false)
report("preview", prev != nil && prev!.width == 160, "\(prev?.width ?? 0)×\(prev?.height ?? 0)")
let finished = Finisher.finish(gpu)
try ImageExport.writeJPEG(finished.display, to: URL(fileURLWithPath: outDir).appendingPathComponent("gpu_final.jpg"), orientation: 6)
print("notes:", finished.notes)

// 4. Master dark: constant offset removed after calibration.
stacker.clearDark()
let darkFrame = RGBImage(width: w, height: h, repeating: 0)
for _ in 0..<4 { try load(mosaic(darkFrame, hotPixel: false, darkOffset: 0.01)); stacker.accumulateDark() }
stacker.finalizeDark()
try load(mosaic(first, hotPixel: false, darkOffset: 0.01))
let calibrated = stacker.currentFrame()
report("master dark", abs(calibrated.g[5000] - first.g[5000]) < 3e-4, "\(calibrated.g[5000]) vs \(first.g[5000])")

print(failures == 0 ? "ALL GPU CHECKS PASSED" : "\(failures) GPU CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
