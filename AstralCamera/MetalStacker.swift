import AstralCore
import CoreImage
import CoreVideo
import Metal
import simd

// Swift mirrors of the Shaders.metal structs (natural alignment matches MSL).

struct BinParams {
    var black: SIMD4<Float>
    var colorIndex: SIMD4<UInt32>
    var rawWidth: UInt32
    var rawHeight: UInt32
    var rawRowElements: UInt32
    var outWidth: UInt32
    var outHeight: UInt32
    var invRange: Float
    var useDark: UInt32
    var hotRatio: Float
    var rawOriginX: UInt32 = 0
    var rawOriginY: UInt32 = 0
    var pad0: UInt32 = 0
    var pad1: UInt32 = 0
}

struct WarpParams {
    var G: simd_float3x3
    var lutCenter: SIMD2<Float>
    var lutMaxRadius: Float
    var lutCount: UInt32
    var width: UInt32
    var height: UInt32
    var useLUT: UInt32
    var frameWeight: Float
    var lambdaS: Float
    var lambdaR: Float
    var modelError2: Float
    var kappa2: Float
    var rejectS: Float
    var rejectT: Float
    var robust: UInt32
    var resetAfter: UInt32
    var useOcclusion: UInt32
    var warmupCount: UInt32
    var resetMaxWeight: Float = 6
    var plainEnabled: UInt32 = 1
}

struct PreviewParams {
    var srcWidth: UInt32
    var srcHeight: UInt32
    var outWidth: UInt32
    var outHeight: UInt32
    var originX: UInt32
    var originY: UInt32
    var step: UInt32
    var source: UInt32
}

/// RAW samples copied out of AVFoundation's buffer as soon as the photo arrives. Holding the camera's
/// own buffer until processing finished starved its small pool: on the fourth night about two of every
/// three captures failed with -11800/-12686.
struct RawImage: Sendable {
    var data: Data
    var width: Int
    var height: Int
    var rowBytes: Int
    var pixelFormat: OSType

    init?(copying pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        width = CVPixelBufferGetWidth(pb)
        height = CVPixelBufferGetHeight(pb)
        rowBytes = CVPixelBufferGetBytesPerRow(pb)
        pixelFormat = CVPixelBufferGetPixelFormatType(pb)
        data = Data(bytes: base, count: rowBytes * height)
    }
}

/// Black/white level of the RAW sensor data, read once per session from the DNG metadata.
struct RawLevels {
    var black: SIMD4<Float>
    var white: Float
    /// Image area inside the sensor buffer (the iPhone 17 Pro buffer has dead margin columns).
    var crop: RawCrop?
}

struct RawCrop: Equatable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
}

enum StackerError: Error {
    case noMetal
    case unsupportedPixelBuffer
    case rawDecodeFailed
}

/// GPU side of the pipeline: RAW binning, registered robust merge (sky), static merge (foreground),
/// master dark and preview. Mirrors `CPUStacker` in AstralCore, which is the tested reference.
final class MetalStacker {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipelines: [String: MTLComputePipelineState] = [:]
    private lazy var ciContext = CIContext(mtlDevice: device, options: [.workingColorSpace: NSNull(), .cacheIntermediates: false])

    private(set) var width = 0
    private(set) var height = 0
    private(set) var skyFrames = 0
    private(set) var darkFrames = 0
    private(set) var hasMasterDark = false

    private var rawBuffer: MTLBuffer?
    private var frame: MTLBuffer!
    private var skyAcc: MTLBuffer!
    private var skyStats: MTLBuffer!
    private var fgAcc: MTLBuffer!
    private var fgStats: MTLBuffer!
    private var skyPlain: MTLBuffer!
    private var darkAcc: MTLBuffer!
    private var dark: MTLBuffer!
    private var occlusion: MTLBuffer!
    private var warm: [MTLBuffer] = []
    private var previewBuffer: MTLBuffer?
    private var lutForward: MTLBuffer!
    private var lutInverse: MTLBuffer!
    private var useOcclusion = false

    /// `library` defaults to the app's compiled Shaders.metal (tests pass one built from source).
    init(library: MTLLibrary? = nil) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = library ?? device.makeDefaultLibrary() else { throw StackerError.noMetal }
        self.device = device
        self.queue = queue
        for name in ["binBayer", "packRGB", "warpToWarmup", "seedFromWarmup", "accumulateSky",
                     "accumulateForeground", "accumulateDark", "previewDownsample"] {
            guard let fn = library.makeFunction(name: name) else { throw StackerError.noMetal }
            pipelines[name] = try device.makeComputePipelineState(function: fn)
        }
        lutForward = device.makeBuffer(length: 8, options: .storageModeShared)
        lutInverse = device.makeBuffer(length: 8, options: .storageModeShared)
    }

    // MARK: - Allocation

    /// Allocates working buffers for a binned frame size; keeps them if the size is unchanged.
    func prepare(width: Int, height: Int) {
        guard width != self.width || height != self.height else { return }
        self.width = width
        self.height = height
        let n = width * height
        func make(_ bytes: Int) -> MTLBuffer { device.makeBuffer(length: max(bytes, 16), options: .storageModeShared)! }
        frame = make(n * 16)
        skyAcc = make(n * 16)
        skyStats = make(n * 16)
        fgAcc = make(n * 16)
        fgStats = make(n * 16)
        skyPlain = make(n * 16)
        darkAcc = make(n * 16)
        dark = make(n * 16)
        occlusion = make(n * 4)
        warm = (0..<3).map { _ in make(n * 8) }
        hasMasterDark = false
        darkFrames = 0
        resetStack()
        resetDarkAccumulator()
    }

    func resetStack() {
        guard width > 0 else { return }
        for b in [skyAcc, skyStats, fgAcc, fgStats, skyPlain, occlusion] { memset(b!.contents(), 0, b!.length) }
        skyFrames = 0
        useOcclusion = false
    }

    func resetDarkAccumulator() {
        guard width > 0 else { return }
        memset(darkAcc.contents(), 0, darkAcc.length)
        darkFrames = 0
    }

    // MARK: - Frame input

    /// 14/16-bit Bayer buffer → 2×2 super-pixel linear RGB (+ luma in .w) with hot-pixel filtering.
    func load(bayer raw: RawImage, colorIndex: SIMD4<UInt32>, levels: RawLevels, hotRatio: Float = 8) throws {
        try raw.data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { throw StackerError.unsupportedPixelBuffer }
            try load(bayer: base, rowBytes: raw.rowBytes, width: raw.width, height: raw.height,
                     colorIndex: colorIndex, levels: levels, hotRatio: hotRatio)
        }
    }

    func load(bayer base: UnsafeRawPointer, rowBytes: Int, width rawW: Int, height rawH: Int,
              colorIndex: SIMD4<UInt32>, levels: RawLevels, hotRatio: Float = 8) throws {
        guard rowBytes % 2 == 0 else { throw StackerError.unsupportedPixelBuffer }
        var area = RawCrop(x: 0, y: 0, width: rawW, height: rawH)
        if let c = levels.crop, c.x >= 0, c.y >= 0, c.width >= 64, c.height >= 64,
           c.x + c.width <= rawW, c.y + c.height <= rawH {
            area = c
        }
        prepare(width: area.width / 2, height: area.height / 2)
        let length = rowBytes * rawH
        if rawBuffer == nil || rawBuffer!.length < length {
            rawBuffer = device.makeBuffer(length: length, options: .storageModeShared)
        }
        memcpy(rawBuffer!.contents(), base, length)

        var params = BinParams(black: levels.black, colorIndex: colorIndex,
                               rawWidth: UInt32(area.width), rawHeight: UInt32(area.height),
                               rawRowElements: UInt32(rowBytes / 2), outWidth: UInt32(width), outHeight: UInt32(height),
                               invRange: 1 / max(levels.white - levels.black.max(), 1), useDark: hasMasterDark ? 1 : 0,
                               hotRatio: hotRatio, rawOriginX: UInt32(area.x), rawOriginY: UInt32(area.y))
        run("binBayer", width: width, height: height) { enc in
            enc.setBuffer(rawBuffer, offset: 0, index: 0)
            enc.setBuffer(frame, offset: 0, index: 1)
            enc.setBuffer(dark, offset: 0, index: 2)
            enc.setBytes(&params, length: MemoryLayout<BinParams>.stride, index: 3)
        }
    }

    /// Fallback for RAW formats the binning kernel does not understand: CIRAWFilter, linear, half size.
    func load(dng data: Data) throws {
        guard let filter = CIRAWFilter(imageData: data, identifierHint: nil) else { throw StackerError.rawDecodeFailed }
        filter.scaleFactor = 0.5
        filter.isGamutMappingEnabled = false
        filter.isLensCorrectionEnabled = false
        filter.luminanceNoiseReductionAmount = 0
        filter.colorNoiseReductionAmount = 0
        filter.sharpnessAmount = 0
        filter.contrastAmount = 0
        filter.detailAmount = 0
        filter.localToneMapAmount = 0
        filter.boostAmount = 0
        filter.baselineExposure = 0
        guard let image = filter.outputImage else { throw StackerError.rawDecodeFailed }
        let extent = image.extent.integral
        prepare(width: Int(extent.width), height: Int(extent.height))
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        guard let texture = device.makeTexture(descriptor: desc), let cb = queue.makeCommandBuffer() else {
            throw StackerError.rawDecodeFailed
        }
        ciContext.render(image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)),
                         to: texture, commandBuffer: cb, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                         colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!)
        cb.commit()
        cb.waitUntilCompleted()
        var dims = SIMD4<UInt32>(UInt32(width), UInt32(height), hasMasterDark ? 1 : 0, 0)
        run("packRGB", width: width, height: height) { enc in
            enc.setTexture(texture, index: 0)
            enc.setBuffer(frame, offset: 0, index: 0)
            enc.setBuffer(dark, offset: 0, index: 1)
            enc.setBytes(&dims, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 2)
        }
    }

    /// The current binned frame (linear RGB).
    func currentFrame() -> RGBImage {
        let n = width * height
        let ptr = frame.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
        var image = RGBImage(width: width, height: height)
        for i in 0..<n { image.r[i] = ptr[i].x; image.g[i] = ptr[i].y; image.b[i] = ptr[i].z }
        return image
    }

    /// Luma of the current frame for star detection and noise estimation.
    func currentLuma() -> PlanarImage {
        let n = width * height
        let ptr = frame.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
        var pixels = [Float](repeating: 0, count: n)
        for i in 0..<n { pixels[i] = ptr[i].w }
        return PlanarImage(width: width, height: height, pixels: pixels)
    }

    // MARK: - Stacking

    func accumulateSky(homography: Homography, distortion: LensDistortion?, noise: NoiseModel,
                       weighting: RobustWeighting, frameWeight: Float, accumulatePlain: Bool = true) {
        var params = WarpParams(G: homography.floatMatrix, lutCenter: .zero, lutMaxRadius: 1, lutCount: 2,
                                width: UInt32(width), height: UInt32(height), useLUT: 0, frameWeight: frameWeight,
                                lambdaS: Float(noise.lambdaS), lambdaR: Float(noise.lambdaR),
                                modelError2: Float(noise.relativeModelError * noise.relativeModelError),
                                kappa2: Float(weighting.kappa * weighting.kappa), rejectS: Float(weighting.s),
                                rejectT: Float(weighting.t), robust: 1, resetAfter: UInt32(weighting.resetAfter),
                                useOcclusion: useOcclusion ? 1 : 0, warmupCount: 0,
                                resetMaxWeight: Float(weighting.resetMaxWeight), plainEnabled: accumulatePlain ? 1 : 0)
        if let distortion, distortion.forward.count > 1, distortion.inverse.count > 1 {
            uploadLUT(distortion)
            params.useLUT = 1
            params.lutCenter = SIMD2(Float(distortion.center.x), Float(distortion.center.y))
            params.lutMaxRadius = Float(distortion.maxRadius)
            params.lutCount = UInt32(min(distortion.forward.count, distortion.inverse.count))
        }

        if skyFrames < CPUStacker.warmupFrames {
            run("warpToWarmup", width: width, height: height) { enc in
                enc.setBuffer(frame, offset: 0, index: 0)
                enc.setBuffer(warm[skyFrames], offset: 0, index: 1)
                enc.setBytes(&params, length: MemoryLayout<WarpParams>.stride, index: 2)
                enc.setBuffer(lutForward, offset: 0, index: 3)
                enc.setBuffer(lutInverse, offset: 0, index: 4)
                enc.setBuffer(occlusion, offset: 0, index: 5)
                enc.setBuffer(skyPlain, offset: 0, index: 6)
            }
            skyFrames += 1
            if skyFrames == CPUStacker.warmupFrames { seedWarmup(params: params, count: skyFrames) }
            return
        }
        run("accumulateSky", width: width, height: height) { enc in
            enc.setBuffer(frame, offset: 0, index: 0)
            enc.setBuffer(skyAcc, offset: 0, index: 1)
            enc.setBuffer(skyStats, offset: 0, index: 2)
            enc.setBytes(&params, length: MemoryLayout<WarpParams>.stride, index: 3)
            enc.setBuffer(lutForward, offset: 0, index: 4)
            enc.setBuffer(lutInverse, offset: 0, index: 5)
            enc.setBuffer(occlusion, offset: 0, index: 6)
            enc.setBuffer(skyPlain, offset: 0, index: 7)
        }
        skyFrames += 1
    }

    private func seedWarmup(params: WarpParams, count: Int) {
        var p = params
        p.warmupCount = UInt32(count)
        p.frameWeight = 1
        run("seedFromWarmup", width: width, height: height) { enc in
            enc.setBuffer(warm[0], offset: 0, index: 0)
            enc.setBuffer(warm[1], offset: 0, index: 1)
            enc.setBuffer(warm[2], offset: 0, index: 2)
            enc.setBuffer(skyAcc, offset: 0, index: 3)
            enc.setBuffer(skyStats, offset: 0, index: 4)
            enc.setBytes(&p, length: MemoryLayout<WarpParams>.stride, index: 5)
        }
    }

    private func uploadLUT(_ distortion: LensDistortion) {
        func upload(_ table: [Float]) -> MTLBuffer? {
            table.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        }
        if lutForward.length != distortion.forward.count * 4 { lutForward = upload(distortion.forward) }
        if lutInverse.length != distortion.inverse.count * 4 { lutInverse = upload(distortion.inverse) }
    }

    func accumulateForeground() {
        var dims = SIMD2<UInt32>(UInt32(width), UInt32(height))
        run("accumulateForeground", width: width, height: height) { enc in
            enc.setBuffer(frame, offset: 0, index: 0)
            enc.setBuffer(fgAcc, offset: 0, index: 1)
            enc.setBuffer(fgStats, offset: 0, index: 2)
            enc.setBytes(&dims, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 3)
        }
    }

    /// Ground mask on the static sensor grid (1 = ground); sky samples landing there are skipped.
    func setOcclusion(_ mask: PlanarImage?) {
        guard let mask, mask.width == width, mask.height == height else { useOcclusion = false; return }
        mask.pixels.withUnsafeBytes { _ = memcpy(occlusion.contents(), $0.baseAddress!, $0.count) }
        useOcclusion = true
    }

    // MARK: - Darks

    func accumulateDark() {
        var dims = SIMD2<UInt32>(UInt32(width), UInt32(height))
        run("accumulateDark", width: width, height: height) { enc in
            enc.setBuffer(frame, offset: 0, index: 0)
            enc.setBuffer(darkAcc, offset: 0, index: 1)
            enc.setBytes(&dims, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 2)
        }
        darkFrames += 1
    }

    /// Master dark = mean of the dark frames (they were binned without dark subtraction).
    /// Returns the master dark's median luma; a covered lens gives ≈ 0 above black.
    @discardableResult
    func finalizeDark() -> Float {
        guard darkFrames > 0 else { return 0 }
        let n = width * height
        let acc = darkAcc.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
        let out = dark.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
        var samples: [Float] = []
        samples.reserveCapacity(n / 49 + 1)
        for i in 0..<n {
            out[i] = SIMD4(acc[i].x, acc[i].y, acc[i].z, 0) / max(acc[i].w, 1)
            if i % 49 == 0 { samples.append((out[i].x + 2 * out[i].y + out[i].z) * 0.25) }
        }
        hasMasterDark = true
        return Statistics.median(samples)
    }

    func clearDark() {
        hasMasterDark = false
        resetDarkAccumulator()
    }

    // MARK: - Readback

    func readStack() -> StackResult? {
        guard width > 0 else { return nil }
        if skyFrames > 0 && skyFrames < CPUStacker.warmupFrames {
            let params = WarpParams(G: matrix_identity_float3x3, lutCenter: .zero, lutMaxRadius: 1, lutCount: 2,
                                    width: UInt32(width), height: UInt32(height), useLUT: 0, frameWeight: 1,
                                    lambdaS: 0, lambdaR: 1, modelError2: 0, kappa2: 16, rejectS: 1.05, rejectT: 0.05,
                                    robust: 0, resetAfter: 8, useOcclusion: 0, warmupCount: 0)
            seedWarmup(params: params, count: skyFrames)
            skyFrames = CPUStacker.warmupFrames
        }
        let n = width * height
        let sAcc = skyAcc.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
        let sStats = skyStats.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
        let fAcc = fgAcc.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
        let fStats = fgStats.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
        let plain = skyPlain.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
        var plainMean = PlanarImage(width: width, height: height, repeating: .nan)
        var plainVar = PlanarImage(width: width, height: height, repeating: .nan)
        var sky = RGBImage(width: width, height: height)
        var fg = RGBImage(width: width, height: height)
        var skyWeight = PlanarImage(width: width, height: height)
        var skyVar = PlanarImage(width: width, height: height, repeating: .greatestFiniteMagnitude)
        var fgVar = PlanarImage(width: width, height: height)
        var frameCount: Float = 0
        for i in 0..<n {
            let a = sAcc[i]
            if a.w > 0 {
                sky.r[i] = a.x / a.w; sky.g[i] = a.y / a.w; sky.b[i] = a.z / a.w
                skyWeight.pixels[i] = a.w
                skyVar.pixels[i] = sStats[i].y / a.w
            }
            let p = plain[i]
            if p.z > 0 {
                let m = p.x / p.z
                plainMean.pixels[i] = m
                plainVar.pixels[i] = max(p.y / p.z - m * m, 0)
            }
            let f = fAcc[i]
            if f.w > 0 {
                fg.r[i] = f.x / f.w; fg.g[i] = f.y / f.w; fg.b[i] = f.z / f.w
                fgVar.pixels[i] = fStats[i].y / f.w
                frameCount = max(frameCount, f.w)
            }
        }
        return StackResult(sky: sky, skyWeight: skyWeight, skyVariance: skyVar, foreground: fg,
                           foregroundVariance: fgVar, frameCount: Int(frameCount),
                           skyPlainMean: plainMean, skyPlainVariance: plainVar)
    }

    // MARK: - Preview

    enum PreviewSource: UInt32 { case stack = 0, frame = 1 }

    /// Small linear preview; `zoom` crops the centre 1:1 (focusing aid).
    func preview(source: PreviewSource, maxDimension: Int, zoom: Bool) -> RGBImage? {
        guard width > 0 else { return nil }
        let step = zoom ? 1 : max(1, Int((Double(max(width, height)) / Double(maxDimension)).rounded(.up)))
        let outW = zoom ? min(maxDimension, width) : width / step
        let outH = zoom ? min(maxDimension * height / max(width, 1), height) : height / step
        let originX = zoom ? (width - outW) / 2 : 0, originY = zoom ? (height - outH) / 2 : 0
        let bytes = outW * outH * 16
        if previewBuffer == nil || previewBuffer!.length < bytes {
            previewBuffer = device.makeBuffer(length: bytes, options: .storageModeShared)
        }
        var params = PreviewParams(srcWidth: UInt32(width), srcHeight: UInt32(height), outWidth: UInt32(outW),
                                   outHeight: UInt32(outH), originX: UInt32(originX), originY: UInt32(originY),
                                   step: UInt32(step), source: source.rawValue)
        run("previewDownsample", width: outW, height: outH) { enc in
            enc.setBuffer(skyAcc, offset: 0, index: 0)
            enc.setBuffer(fgAcc, offset: 0, index: 1)
            enc.setBuffer(frame, offset: 0, index: 2)
            enc.setBuffer(previewBuffer, offset: 0, index: 3)
            enc.setBytes(&params, length: MemoryLayout<PreviewParams>.stride, index: 4)
        }
        let ptr = previewBuffer!.contents().bindMemory(to: SIMD4<Float>.self, capacity: outW * outH)
        var image = RGBImage(width: outW, height: outH)
        for i in 0..<(outW * outH) { image.r[i] = ptr[i].x; image.g[i] = ptr[i].y; image.b[i] = ptr[i].z }
        return image
    }

    // MARK: - Dispatch

    private func run(_ name: String, width: Int, height: Int, encode: (MTLComputeCommandEncoder) -> Void) {
        guard let pipeline = pipelines[name], let cb = queue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(pipeline)
        encode(enc)
        let tw = pipeline.threadExecutionWidth
        let th = max(1, pipeline.maxTotalThreadsPerThreadgroup / tw)
        enc.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
    }
}
