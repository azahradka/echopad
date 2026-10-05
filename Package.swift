// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "echopad",
    platforms: [.macOS("26.0")],
    dependencies: [
        // Our reviewed forks, on their `notetaker` branch; to be pinned with `revision:`
        // once those branches are stable.
        .package(url: "https://github.com/azahradka/ScribeKit.git", branch: "notetaker"),
        .package(url: "https://github.com/azahradka/SystemAudioKit.git", branch: "notetaker"),
    ],
    targets: [
        .target(
            name: "EchoPadKit",
            dependencies: [
                .product(name: "ScribeKit", package: "ScribeKit"),
                .product(name: "SystemAudioKit", package: "SystemAudioKit"),
            ],
            path: "Sources/EchoPadKit",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Carbon"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .executableTarget(
            name: "echopad",
            dependencies: ["EchoPadKit"],
            path: "Sources/EchoPad",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "EchoPadKitTests",
            dependencies: ["EchoPadKit"],
            path: "Tests/EchoPadKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
