// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Greycard",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Greycard",
            path: "Sources/Greycard"
        )
    ]
)
