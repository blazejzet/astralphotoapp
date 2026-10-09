import AstralCore
import Foundation
import Photos

struct ExportedSession {
    var folder: URL
    var jpeg: URL
    var linearTIFF: URL
    var savedToPhotos: Bool
}

/// Writes the session to Documents/AstralCamera/<date>/ (visible in the Files app) and the
/// stretched JPEG to the photo library.
enum ExportService {
    static func export(_ finished: FinishedImage, stack: StackResult?, stats: LiveStats, orientation: UInt32,
                       summary: [String]) async throws -> ExportedSession {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let docs = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = docs.appendingPathComponent("AstralCamera").appendingPathComponent(formatter.string(from: Date()))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let jpeg = folder.appendingPathComponent("astral.jpg")
        let tiff = folder.appendingPathComponent("astral_linear.tif")
        try ImageExport.writeJPEG(finished.display, to: jpeg, orientation: orientation)
        try ImageExport.writeLinearTIFF(finished.linear, to: tiff, orientation: orientation)
        // Sky mask for diagnostics (white = sky stack, black = foreground stack).
        if let mask = ImageExport.makeCGImage8(RGBImage(gray: finished.skyMask)) {
            try? ImageExport.write(mask, to: folder.appendingPathComponent("mask.png"), type: .png, orientation: orientation)
        }
        if let stack {
            // Raw two-layer stacks (sensor grid, no orientation) for offline analysis.
            try? ImageExport.writeLinearTIFF(stack.sky, to: folder.appendingPathComponent("diag_sky.tif"))
            try? ImageExport.writeLinearTIFF(stack.foreground, to: folder.appendingPathComponent("diag_ground.tif"))
            let variances = RGBImage(width: stack.sky.width, height: stack.sky.height,
                                     r: stack.skyVariance.pixels.map { min($0, 1) }, g: stack.foregroundVariance.pixels,
                                     b: stack.skyWeight.pixels)
            try? ImageExport.writeLinearTIFF(variances, to: folder.appendingPathComponent("diag_skyvar_groundvar_weight.tif"))
            if let mean = stack.skyPlainMean, let variance = stack.skyPlainVariance {
                let plain = RGBImage(width: mean.width, height: mean.height, r: mean.pixels.map { $0.isFinite ? $0 : -1 },
                                     g: variance.pixels.map { $0.isFinite ? $0 : -1 },
                                     b: [Float](repeating: 0, count: mean.pixels.count))
                try? ImageExport.writeLinearTIFF(plain, to: folder.appendingPathComponent("diag_skyplain_mean_var.tif"))
            }
        }
        let log = (summary + finished.notes).joined(separator: "\n")
        try log.write(to: folder.appendingPathComponent("session.txt"), atomically: true, encoding: .utf8)

        var saved = false
        if await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: jpeg, options: nil)
                }
                saved = true
            } catch {
                saved = false
            }
        }
        return ExportedSession(folder: folder, jpeg: jpeg, linearTIFF: tiff, savedToPhotos: saved)
    }
}
