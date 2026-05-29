// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PDFSigner",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure-logic library (coordinate math, geometry). Unit-testable in isolation,
        // no UI dependencies — the highest-risk Phase 2 code lives here.
        .target(
            name: "PDFSignerKit",
            path: "Sources/PDFSignerKit"
        ),
        .executableTarget(
            name: "PDFSigner",
            dependencies: ["PDFSignerKit"],
            path: "Sources/PDFSigner"
        ),
        .testTarget(
            name: "PDFSignerKitTests",
            dependencies: ["PDFSignerKit"],
            path: "Tests/PDFSignerKitTests"
        ),
    ]
)
