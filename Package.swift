// swift-tools-version: 5.9
//
// Net Report - a macOS application for running a local amateur radio net.
// Copyright (C) 2026  kidvelvet (W7SKW)
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.
//

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
