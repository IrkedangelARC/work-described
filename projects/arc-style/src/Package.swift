// swift-tools-version: 5.9
//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import PackageDescription

// ARCStyle: the ONE copy of ARC Style for every Swift ARC app (tokens, the
// console type rule, the module chrome). A local path dependency, like
// ARCShowFormat. Eight copies of ARCTheme.swift had drifted into six variants.
let package = Package(
    name: "ARCStyle",
    // iOS too since 2026-09-17: ARC Stage Timer builds for iPad (its stage display and remote), and ARCStyle is
    // pure SwiftUI with no AppKit, so the console language is the same on both.
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "ARCStyle", targets: ["ARCStyle"])],
    targets: [
        .target(name: "ARCStyle"),
        .testTarget(name: "ARCStyleTests", dependencies: ["ARCStyle"]),
    ]
)
