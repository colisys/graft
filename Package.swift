// swift-tools-version: 5.9
//
// Graft — run Linux desktop applications as native macOS .app bundles.
// Copyright (C) 2026 The Graft Authors
// SPDX-License-Identifier: GPL-3.0-or-later
//
import PackageDescription

let package = Package(
    name: "Graft",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Graft", targets: ["GraftApp"]),
        .executable(name: "GraftLauncher", targets: ["GraftLauncher"]),
        .library(name: "GraftCore", targets: ["GraftCore"])
    ],
    targets: [
        .target(
            name: "GraftCore",
            path: "Sources/GraftCore"
        ),
        .executableTarget(
            name: "GraftApp",
            dependencies: ["GraftCore"],
            path: "Sources/GraftApp"
        ),
        .executableTarget(
            name: "GraftLauncher",
            path: "Sources/GraftLauncher"
        ),
        .testTarget(
            name: "GraftCoreTests",
            dependencies: ["GraftCore"],
            path: "Tests/GraftCoreTests"
        )
    ]
)
