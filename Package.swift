// swift-tools-version:5.9
import PackageDescription

var products: [Product] = [
    .library(name: "ArchiveKit", targets: ["ArchiveKit"]),
    .executable(name: "mif", targets: ["mif"]),
]

var targets: [Target] = [
    .target(name: "ArchiveKit"),
    .executableTarget(name: "mif", dependencies: ["ArchiveKit"]),
    .testTarget(name: "ArchiveKitTests", dependencies: ["ArchiveKit"]),
]

// The SwiftUI app only builds on macOS; the core library and CLI are cross-platform.
#if os(macOS)
products.append(.executable(name: "MacItFree", targets: ["MacItFree"]))
targets.append(.executableTarget(name: "MacItFree", dependencies: ["ArchiveKit"]))
#endif

let package = Package(
    name: "MacItFree",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
