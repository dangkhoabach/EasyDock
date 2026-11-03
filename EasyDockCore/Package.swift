// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EasyDockCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EasyDockCore", targets: ["EasyDockCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .target(name: "EasyDockCore", dependencies: [
            .product(name: "GRDB", package: "GRDB.swift")
        ]),
        .testTarget(name: "EasyDockCoreTests", dependencies: ["EasyDockCore"]),
    ]
)
