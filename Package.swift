// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Oppy",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Oppy", targets: ["Oppy"])
    ],
    targets: [
        .executableTarget(
            name: "Oppy",
            path: "MacMenuBarApp/Sources/Oppy"
        )
    ]
)
