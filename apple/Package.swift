// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BureaucratPdf",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure-logic library (coordinate math, geometry). Unit-testable in isolation,
        // no UI dependencies — the highest-risk Phase 2 code lives here.
        .target(
            name: "BureaucratPdfKit",
            path: "Sources/BureaucratPdfKit"
        ),
        .executableTarget(
            name: "BureaucratPdf",
            dependencies: ["BureaucratPdfKit"],
            path: "Sources/BureaucratPdf"
        ),
        .testTarget(
            name: "BureaucratPdfKitTests",
            dependencies: ["BureaucratPdfKit"],
            path: "Tests/BureaucratPdfKitTests"
        ),
    ]
)
