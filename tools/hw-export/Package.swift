// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "kappy-hw-export",
    platforms: [.macOS(.v12)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.26.0"),
    ],
    targets: [
        .executableTarget(
            name: "kappy-hw-export",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Sources/kappy-hw-export",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Foundation"),
            ]
        ),
    ]
)
