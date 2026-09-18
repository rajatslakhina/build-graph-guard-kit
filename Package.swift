// swift-tools-version: 6.0
import PackageDescription

// Platforms are deliberately limited to the two the CI matrix actually builds:
// - iOS, built by the macOS job via `xcodebuild -destination 'generic/platform=iOS Simulator'`
// - macOS, built by the same job and by the demo app's resolution step
// Linux has no platform clause (SwiftPM treats it as always-available) and is
// covered by the `swift build -Xswiftc -warnings-as-errors` + `swift test` job.
// Declaring watchOS/tvOS here would be an unverified claim, so they are absent.
let package = Package(
    name: "BuildGraphGuard",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "BuildGraphGuard", targets: ["BuildGraphGuard"]),
        .library(name: "BuildGraphGuardUI", targets: ["BuildGraphGuardUI"])
    ],
    targets: [
        .target(
            name: "BuildGraphGuard",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "BuildGraphGuardUI",
            dependencies: ["BuildGraphGuard"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BuildGraphGuardTests",
            dependencies: ["BuildGraphGuard"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
