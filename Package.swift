// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Hush",
    platforms: [.macOS(.v13)],
    targets: [
        // libmpv from Homebrew (`brew install mpv`), resolved through pkg-config.
        .systemLibrary(
            name: "CMpv",
            path: "Sources/CMpv",
            pkgConfig: "mpv",
            providers: [.brew(["mpv"])]
        ),
        .executableTarget(
            name: "Hush",
            dependencies: ["CMpv"],
            path: "Sources/Hush",
            swiftSettings: [.unsafeFlags(["-suppress-warnings"])]
        ),
    ]
)
