// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RoomPlayKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "RoomPlayKit", targets: ["RoomPlayKit"])],
    targets: [
        .target(name: "RoomPlayKit"),
        .testTarget(name: "RoomPlayKitTests", dependencies: ["RoomPlayKit"])
    ]
)
