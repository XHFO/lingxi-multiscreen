// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "LinxDisplay",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "C6DisplayRenderer", path: "Sources/C6DisplayRenderer", publicHeadersPath: "include"),
        .target(name: "CPicoBoardRenderer", path: "Sources/CPicoBoardRenderer",
                exclude: ["NOTICE.md", "source-manifest.json", "vendor/cJSON/LICENSE"],
                sources: ["main/system/pico_board_data.c", "main/system/pico_board_render.c",
                          "components/read_pico_home_link/home_link_json.c", "pico_board_sha.c"],
                publicHeadersPath: "include",
                cSettings: [.define("PICO_BOARD_PORTABLE"), .headerSearchPath("private"), .headerSearchPath("vendor/cJSON")]),
        .target(
            name: "LinxDisplayCore",
            dependencies: ["C6DisplayRenderer", "CPicoBoardRenderer"],
            path: "Sources/LinxDisplayCore",
            linkerSettings: [
                .linkedFramework("JavaScriptCore"),
                .linkedFramework("CoreBluetooth")
            ]
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
    ],
    // 保持 Swift 5 语言模式：仅提升 tools 版本以支持 .v26 平台（macOS 26 官方玻璃 API），
    // 不引入 Swift 6 严格并发检查，避免现有代码大范围迁移
    swiftLanguageModes: [.v5]
)
