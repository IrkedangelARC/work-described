// swift-tools-version: 5.9
//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import PackageDescription

// ARCShowFormat: the contract between ARC Capture (writer) and ARC Presenter
// (reader). Typed deck manifest, show.json, the deck verifier, the show log
// core. A local path dependency of both apps, like ARCDeckLink.
let package = Package(
    name: "ARCShowFormat",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ARCShowFormat", targets: ["ARCShowFormat"])],
    targets: [
        .target(name: "ARCShowFormat"),
        .testTarget(name: "ARCShowFormatTests", dependencies: ["ARCShowFormat"]),
    ]
)
