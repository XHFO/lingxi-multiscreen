// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LinxDisplay",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "LinxDisplayCore",
            path: "Sources/LinxDisplayCore"
        ),
        .executableTarget(
            name: "LinxDisplayApp",
            dependencies: ["LinxDisplayCore"],
            path: "Sources/LinxDisplayApp"
        ),
        .executableTarget(
            name: "LinxDisplaySmokeTests",
            dependencies: ["LinxDisplayCore"],
            path: "Tests/LinxDisplaySmokeTests"
        )
    ]
)
