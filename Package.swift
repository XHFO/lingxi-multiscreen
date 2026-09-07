// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "LinxDisplay",
    platforms: [.macOS(.v26)],
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
        ),
        // ESP8266 AI Mac 240x240 experimental build.  It intentionally has a
        // separate executable, bundle identifier and data directory so it can
        // never read or overwrite the production MultiScreen configuration.
        .executableTarget(
            name: "AIMacScreenApp",
            dependencies: ["LinxDisplayCore"],
            path: "Sources/AIMacScreenApp"
        )
    ],
    // 保持 Swift 5 语言模式：仅提升 tools 版本以支持 .v26 平台（macOS 26 官方玻璃 API），
    // 不引入 Swift 6 严格并发检查，避免现有代码大范围迁移
    swiftLanguageModes: [.v5]
)
