// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MellowClean",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MellowCleanApp", targets: ["MellowClean"]),
               .executable(name: "mellowclean", targets: ["MellowCLI"])],
    targets: [.target(name: "MellowCore"),
              .executableTarget(name: "MellowClean", dependencies: ["MellowCore"]),
              .executableTarget(name: "MellowCLI", dependencies: ["MellowCore"]),
              .testTarget(name: "MellowCoreTests", dependencies: ["MellowCore"])]
)
