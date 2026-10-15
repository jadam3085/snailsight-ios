// swift-tools-version:5.9
// Pure maths/formatting for SnailSight: no ARKit/RealityKit/UIKit, so `swift test` runs on the macOS
// CI runner without a simulator. The iOS app links this package (project.yml `packages:`).
import PackageDescription

// Linux CI (ubuntu-latest, 1x minutes) has no `simd` module: the simd-based files are excluded there so the
// pure-Swift remainder still builds + tests. Apple platforms (macOS dev, iOS app) build everything.
#if os(Linux)
let simdSources = ["Geometry.swift", "ScanViewMath.swift", "ScanCatalog.swift", "ScanLabels.swift",
                   "Measure.swift", "ScanDrone.swift", "ObjectScan.swift"]
let simdTests = ["MiscTests.swift", "GeometryTests.swift", "SharpCaptureTests.swift", "ScanTests.swift",
                 "ScanDroneTests.swift", "ScanLabelTests.swift", "ObjectScanTests.swift"]
#else
let simdSources: [String] = []
let simdTests: [String] = []
#endif

let package = Package(
    name: "SnailSightCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "SnailSightCore", targets: ["SnailSightCore"])],
    targets: [
        .target(name: "SnailSightCore", exclude: simdSources),
        .testTarget(name: "SnailSightCoreTests", dependencies: ["SnailSightCore"], exclude: simdTests),
    ]
)
