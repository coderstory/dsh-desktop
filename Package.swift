// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DshDesktop",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DshDesktop", targets: ["DshDesktop"]),
    ],
    targets: [
        .executableTarget(
            name: "DshDesktop",
            path: "Sources/DshDesktop",
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "DshDesktopTests",
            dependencies: ["DshDesktop"],
            path: "Tests/DshDesktopTests"
        ),
    ]
)
