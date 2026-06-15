// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HiSleep",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "HiSleep",
            path: "Sources/HiSleep"
        )
    ]
)
