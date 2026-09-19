// swift-tools-version:6.0
import PackageDescription

// CatchTallyKit — pure-domain core for Catch Tally.
// No UI, no networking, no Apple-only frameworks: Linux-testable by design.
let package = Package(
    name: "CatchTallyKit",
    platforms: [
        .iOS("26.0"),
    ],
    products: [
        .library(name: "CatchTallyKit", targets: ["CatchTallyKit"]),
    ],
    targets: [
        .target(name: "CatchTallyKit"),
        .testTarget(name: "CatchTallyKitTests", dependencies: ["CatchTallyKit"]),
    ]
)
