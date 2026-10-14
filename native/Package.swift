// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "TabbyNative",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "TabbyNative", targets: ["TabbyNative"])],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", branch: "main"),
        .package(path: "Vendor/Citadel"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
    ],
    targets: [
        .executableTarget(name: "TabbyNative", dependencies: ["SwiftTerm", "Citadel", "Yams"], resources: [.copy("Resources/AIManual")]),
        .testTarget(name: "TabbyNativeTests", dependencies: ["TabbyNative"]),
    ],
    swiftLanguageModes: [.v5]
)
