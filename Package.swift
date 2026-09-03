// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CoffeeBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CoffeeBar",
            path: "Sources/CoffeeBar"
        )
    ]
)
