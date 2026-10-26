// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NutritionCore",
    platforms: [.macOS(.v14), .iOS("27.0")],
    products: [.library(name: "NutritionCore", targets: ["NutritionCore"])],
    targets: [
        .target(name: "NutritionCore"),
        .testTarget(name: "NutritionCoreTests", dependencies: ["NutritionCore"])
    ],
    swiftLanguageModes: [.v6]
)
