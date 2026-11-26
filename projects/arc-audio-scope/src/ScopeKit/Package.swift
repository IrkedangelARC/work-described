// swift-tools-version: 6.0
//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import PackageDescription

// ScopeKit: every analyzer and model type of ARC Audio Scope that needs no device and no UI.
// Each analyzer takes samples and a sample rate, so `swift test` proves the numbers without
// launching the app, opening an interface or asking for the microphone.
let package = Package(
    name: "ScopeKit",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "ScopeKit", targets: ["ScopeKit"])],
    targets: [
        .target(name: "ScopeKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ScopeKitTests", dependencies: ["ScopeKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
