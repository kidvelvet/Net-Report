// swift-tools-version: 5.9
import PackageDescription

// Net Report — a native SwiftUI macOS app (Apple Silicon, macOS 14+) for running a
// local ham radio net. Redevelopment of the original Python `ham_lookup.py` CLI.
//
//   • NetReportKit  — platform-agnostic core: models, QRZ XML API client,
//                     radiogram/NTS PDF generation, and the message-index CSV.
//   • NetReport     — the SwiftUI application that drives the net workflow.
//
// Build:  swift build            (debug)
//         swift build -c release  then scripts/build-app.sh to bundle NetReport.app
let package = Package(
    name: "NetReport",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NetReport", targets: ["NetReport"]),
        .library(name: "NetReportKit", targets: ["NetReportKit"]),
    ],
    targets: [
        .target(
            name: "NetReportKit",
            path: "Sources/NetReportKit",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "NetReport",
            dependencies: ["NetReportKit"],
            path: "Sources/NetReport"
        ),
        // swift-testing unit tests for the core. Run with `swift test`.
        .testTarget(
            name: "NetReportKitTests",
            dependencies: ["NetReportKit"],
            path: "Tests/NetReportKitTests"
        ),
    ]
)
