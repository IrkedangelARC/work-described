// swift-tools-version: 5.9
//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import PackageDescription

let package = Package(
    name: "ArcDisplayKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ArcDisplayKit", targets: ["ArcDisplayKit"])
    ],
    targets: [
        .target(name: "ArcDisplayKit"),
        .testTarget(name: "ArcDisplayKitTests", dependencies: ["ArcDisplayKit"]),
    ]
)
