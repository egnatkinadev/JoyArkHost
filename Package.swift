// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RoomPlayHost",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "RoomPlayHost", targets: ["RoomPlayHost"])],
    dependencies: [.package(path: "RoomPlayKit")],
    targets: [
        .executableTarget(name: "RoomPlayHost", dependencies: [.product(name: "RoomPlayKit", package: "RoomPlayKit")]),
        .testTarget(name: "RoomPlayHostTests", dependencies: ["RoomPlayHost"])
    ]
)
