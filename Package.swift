// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Schedule",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Schedule", targets: ["Schedule"])],
    targets: [.executableTarget(name: "Schedule")]
)
