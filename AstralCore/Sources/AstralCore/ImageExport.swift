import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageExportError: Error {
    case cannotCreateImage
    case cannotCreateDestination
    case writeFailed
}

public enum ImageExport {
    /// 8-bit sRGB image from a 0…1 display image.
    public static func makeCGImage8(_ image: RGBImage) -> CGImage? {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            bytes[4 * i] = UInt8(min(max(image.r[i], 0), 1) * 255 + 0.5)
            bytes[4 * i + 1] = UInt8(min(max(image.g[i], 0), 1) * 255 + 0.5)
            bytes[4 * i + 2] = UInt8(min(max(image.b[i], 0), 1) * 255 + 0.5)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// 32-bit float linear RGB (readable by Siril, PixInsight, Photoshop).
    public static func makeCGImageFloat(_ image: RGBImage) -> CGImage? {
        let w = image.width, h = image.height
        var floats = [Float](repeating: 1, count: w * h * 4)
        for i in 0..<(w * h) {
            floats[4 * i] = image.r[i]
            floats[4 * i + 1] = image.g[i]
            floats[4 * i + 2] = image.b[i]
        }
        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.linearSRGB) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
            | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: w, height: h, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: w * 16,
                       space: space, bitmapInfo: info, provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    public static func write(_ cgImage: CGImage, to url: URL, type: UTType, orientation: UInt32,
                             quality: Double? = nil) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ImageExportError.cannotCreateDestination
        }
        var props: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
        if let quality { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ImageExportError.writeFailed }
    }

    public static func writeLinearTIFF(_ image: RGBImage, to url: URL, orientation: UInt32 = 1) throws {
        guard let cg = makeCGImageFloat(image) else { throw ImageExportError.cannotCreateImage }
        try write(cg, to: url, type: .tiff, orientation: orientation)
    }

    public static func writeJPEG(_ image: RGBImage, to url: URL, orientation: UInt32 = 1, quality: Double = 0.95) throws {
        guard let cg = makeCGImage8(image) else { throw ImageExportError.cannotCreateImage }
        try write(cg, to: url, type: .jpeg, orientation: orientation, quality: quality)
    }
}
