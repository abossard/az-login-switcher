// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AzLoginSwitcher",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.1")
    ],
    targets: [
        .executableTarget(
            name: "AzLoginSwitcher",
            dependencies: ["Yams"],
            path: "Sources/AzLoginSwitcher"
        ),
        .testTarget(
            name: "AzLoginSwitcherTests",
            dependencies: ["AzLoginSwitcher"],
            path: "Tests/AzLoginSwitcherTests"
        )
    ]
)
