// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 changhun

import PackageDescription

let package = Package(
    name: "DockMinimizer",
    platforms: [.macOS(.v14)],
    products: [
        // bundle.sh 가 `swift build --product DockMinimizer` 로 참조하므로 명시한다.
        .executable(name: "DockMinimizer", targets: ["DockMinimizer"]),
        .executable(name: "DockProbe", targets: ["DockProbe"]),
    ],
    targets: [
        .target(name: "DockMinimizerCore"),
        .executableTarget(name: "DockMinimizer", dependencies: ["DockMinimizerCore"]),
        .executableTarget(name: "DockProbe"),
        .testTarget(name: "DockMinimizerCoreTests", dependencies: ["DockMinimizerCore"]),
    ]
)
