// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

let release = "https://github.com/ggml-org/whisper.cpp/releases/download/b5130"

// whisper.cpp v1.9.4, published as build b5130. Upgrading means changing the
// release and the checksum, then running the parity test against the whisper-cli
// of the same version. Swift Package Manager checks the archive against it.
let package = Package(
    name: "WhisperFramework",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WhisperFramework", targets: ["whisper"])
    ],
    targets: [
        .binaryTarget(
            name: "whisper",
            url: "\(release)/whisper-b5130-xcframework.zip",
            checksum: "033a43b0174e8cf9b366f72e4a428cdcf126f93ad1c87d3fa119a96bed6f231a"
        )
    ]
)
