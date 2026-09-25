// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

// audio.cpp v0.8.1 publishes no framework, so Tools/build-audiocpp.sh builds
// this one from the pinned source. Upgrading means changing the version and the
// commit there, then comparing the app with audiocpp_cli of the same version.
let package = Package(
    name: "AudioCppFramework",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AudioCppFramework", targets: ["audiocpp"])
    ],
    targets: [
        .binaryTarget(name: "audiocpp", path: "audiocpp.xcframework")
    ]
)
