// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PDFLocalCert",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure-logic library (coordinate math, geometry). Unit-testable in isolation,
        // no UI dependencies — the highest-risk Phase 2 code lives here.
        .target(
            name: "PDFLocalCertKit",
            path: "Sources/PDFLocalCertKit"
        ),
        .executableTarget(
            name: "PDFLocalCert",
            dependencies: ["PDFLocalCertKit"],
            path: "Sources/PDFLocalCert"
        ),
        .testTarget(
            name: "PDFLocalCertKitTests",
            dependencies: ["PDFLocalCertKit"],
            path: "tests/PDFLocalCertKitTests"
        ),
    ]
)
