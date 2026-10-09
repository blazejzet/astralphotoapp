import Foundation

/// Autofocus on stars. `lensPosition` = 1.0 is not infinity on iPhones and the right value differs
/// per model and lens, so it is measured: a coarse sweep over the range, then a fine sweep around the
/// best coarse position, sub-step refined by a parabola through the three best fine samples.
///
/// Focus metric: Σ peak S/N of the brightest stars – a sharper PSF concentrates flux into higher
/// peaks and pushes more faint stars over the detection threshold (defocused stars become donuts).
public struct FocusSweep: Sendable {
    public enum Step: Equatable, Sendable {
        /// Set the lens to this position; the next frames are measured.
        case move(Float)
        /// Keep the lens; deliver the next frame.
        case wait
        case finished(Float)
        /// No stars at any position (clouds, lens cap, daylight).
        case failed
    }

    public let range: ClosedRange<Float>
    public let coarseStep: Float
    public let fineStep: Float
    public let fineHalfWidth: Float
    /// Frames discarded after each move: iOS applies lens changes a few exposures late.
    public let settleFrames: Int
    public let minimumScore: Double

    public private(set) var samples: [(position: Float, score: Double)] = []
    private var positions: [Float] = []
    private var index = 0
    private var fine = false
    private var framesAtPosition = 0

    public init(range: ClosedRange<Float> = 0.55...1.0, coarseStep: Float = 0.03, fineStep: Float = 0.006,
                fineHalfWidth: Float = 0.03, settleFrames: Int = 2, minimumScore: Double = 20) {
        self.range = range
        self.coarseStep = coarseStep
        self.fineStep = fineStep
        self.fineHalfWidth = fineHalfWidth
        self.settleFrames = settleFrames
        self.minimumScore = minimumScore
    }

    /// 0…1 for the UI.
    public var progress: Double {
        let coarseCount = Double(Self.grid(range.lowerBound, range.upperBound, coarseStep).count)
        let fineCount = Double(Self.grid(-fineHalfWidth, fineHalfWidth, fineStep).count)
        let done = fine ? coarseCount + Double(index) : Double(index)
        return min(done / (coarseCount + fineCount), 1)
    }

    static func grid(_ a: Float, _ b: Float, _ step: Float) -> [Float] {
        let n = Int(((b - a) / step).rounded(.down))
        return (0...max(n, 0)).map { a + Float($0) * step }
    }

    public mutating func start() -> Step {
        samples = []
        fine = false
        index = 0
        framesAtPosition = 0
        positions = Self.grid(range.lowerBound, range.upperBound, coarseStep)
        return .move(positions[0])
    }

    /// Call once per captured frame with its focus score.
    public mutating func frame(score: Double) -> Step {
        guard !positions.isEmpty else { return .failed }
        framesAtPosition += 1
        if framesAtPosition <= settleFrames { return .wait }
        samples.append((positions[index], score))
        framesAtPosition = 0
        index += 1
        if index < positions.count { return .move(positions[index]) }

        guard let best = samples.max(by: { $0.score < $1.score }), best.score >= minimumScore else { return .failed }
        if !fine {
            fine = true
            index = 0
            positions = Self.grid(-fineHalfWidth, fineHalfWidth, fineStep)
                .map { min(max(best.position + $0, range.lowerBound), range.upperBound) }
            return .move(positions[0])
        }
        return .finished(refined())
    }

    /// Vertex of the parabola through the best fine sample and its neighbours.
    private func refined() -> Float {
        let fineSamples = samples.suffix(positions.count).sorted { $0.position < $1.position }
        guard let k = fineSamples.indices.max(by: { fineSamples[$0].score < fineSamples[$1].score }) else {
            return samples.max { $0.score < $1.score }?.position ?? range.lowerBound
        }
        let best = fineSamples[k]
        guard k > 0, k < fineSamples.count - 1 else { return best.position }
        let (x0, y0) = (Double(fineSamples[k - 1].position), fineSamples[k - 1].score)
        let (x1, y1) = (Double(best.position), best.score)
        let (x2, y2) = (Double(fineSamples[k + 1].position), fineSamples[k + 1].score)
        let denom = (x0 - x1) * (x0 - x2) * (x1 - x2)
        let a = (x2 * (y1 - y0) + x1 * (y0 - y2) + x0 * (y2 - y1)) / denom
        let b = (x2 * x2 * (y0 - y1) + x1 * x1 * (y2 - y0) + x0 * x0 * (y1 - y2)) / denom
        guard a < 0 else { return best.position }
        let vertex = Float(-b / (2 * a))
        return min(max(vertex, Float(x0)), Float(x2))
    }

    /// Σ peak S/N over the brightest stars of a frame.
    public static func score(stars: [Star], noise: Double, count: Int = 40) -> Double {
        guard noise > 0 else { return 0 }
        return stars.sorted { $0.peak > $1.peak }.prefix(count).reduce(0) { $0 + max($1.peak, 0) / noise }
    }
}
