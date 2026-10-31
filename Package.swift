// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Analyxer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Analyxer", targets: ["Analyxer"]),
        .executable(name: "analyxer-cli", targets: ["AnalyxerCLI"]),
        .library(name: "AnalyxerCore", targets: ["AnalyxerCore"])
    ],
    targets: [
        .target(name: "AnalyxerCore"),
        .executableTarget(name: "Analyxer", dependencies: ["AnalyxerCore"]),
        .executableTarget(name: "AnalyxerCLI", dependencies: ["AnalyxerCore"]),
        .testTarget(name: "AnalyxerCoreTests", dependencies: ["AnalyxerCore"])
    ],
    swiftLanguageModes: [.v5]
)
