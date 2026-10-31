// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AndroidAnalyxer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AndroidAnalyxer", targets: ["AndroidAnalyxer"]),
        .executable(name: "android-analyxer-cli", targets: ["AndroidAnalyxerCLI"]),
        .library(name: "AndroidAnalyxerCore", targets: ["AndroidAnalyxerCore"])
    ],
    targets: [
        .target(name: "AndroidAnalyxerCore"),
        .executableTarget(name: "AndroidAnalyxer", dependencies: ["AndroidAnalyxerCore"]),
        .executableTarget(name: "AndroidAnalyxerCLI", dependencies: ["AndroidAnalyxerCore"]),
        .testTarget(name: "AndroidAnalyxerCoreTests", dependencies: ["AndroidAnalyxerCore"])
    ],
    swiftLanguageModes: [.v5]
)
