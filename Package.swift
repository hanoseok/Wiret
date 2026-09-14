// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Wiret",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "Wiret",
            path: "Sources/Wiret"
        ),
        .testTarget(
            name: "WiretTests",
            dependencies: ["Wiret"],
            path: "Tests/WiretTests"
        )
    ]
)
