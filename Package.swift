// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "atgeo-sdk-swift",
    platforms: [.iOS(.v15), .macOS(.v12), .tvOS(.v15), .watchOS(.v8), .visionOS(.v1)],
    products: [
        .library(name: "Atgeo", targets: ["Atgeo"]),
    ],
    targets: [
        .target(name: "Atgeo"),
        .executableTarget(name: "atgeo-e2e", dependencies: ["Atgeo"]),
        .testTarget(
            name: "AtgeoTests",
            dependencies: ["Atgeo"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
