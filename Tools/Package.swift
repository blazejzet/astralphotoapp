// swift-tools-version: 6.0
// Offline tools for field data in tests/<night>/ (run with DEVELOPER_DIR pointing at Xcode):
//   GPUHarness <Shaders.metal> <outDir>          – GPU kernels vs the CPU reference on synthetic RAW
//   Bench <Shaders.metal>                        – per-frame timings at full working resolution
//   Analyze <outDir> <session>/astral_linear.tif – background, noise, star stats, re-stretch
//   Vignette <outDir> <session>:<name>[:x,y,w,h] – falloff + background re-finish, gallery crops
//   MaskLab <outDir> <session>:<frames>          – sky mask on the diag_* stacks, ground tinted red
//   Refinish <outDir> <session>…                 – Finisher re-run on the diag_* stacks (before/after comparisons)
import PackageDescription

let tool: (String) -> Target = {
    .executableTarget(name: $0, dependencies: ["AstralCore"], swiftSettings: [.swiftLanguageMode(.v5)])
}

let package = Package(
    name: "Tools",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../AstralCore")],
    targets: ["GPUHarness", "Analyze", "Vignette", "MaskLab", "Bench", "Refinish"].map(tool)
)
