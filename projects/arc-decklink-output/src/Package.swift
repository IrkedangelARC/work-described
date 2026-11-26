// swift-tools-version:5.9
//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import PackageDescription

let package = Package(
    name: "ARCDeckLink",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ARCDeckLink", targets: ["ARCDeckLink"])
    ],
    targets: [
        .target(
            name: "DeckLinkBridge",
            path: "Sources/DeckLinkBridge",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("DeckLinkSDK")
            ],
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreVideo")
            ]
        ),
        .target(
            name: "ARCDeckLink",
            dependencies: ["DeckLinkBridge"],
            path: "Sources/ARCDeckLink",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreMedia")
            ]
        ),
        .testTarget(
            name: "ARCDeckLinkTests",
            dependencies: ["ARCDeckLink"],
            path: "Tests/ARCDeckLinkTests"
        )
    ],
    cxxLanguageStandard: .cxx17
)
