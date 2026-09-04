// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Lingxi68KnobTester",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Lingxi68KnobTester",
            path: "Sources/Lingxi68KnobTester"
        )
    ]
)
