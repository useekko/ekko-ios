// swift-tools-version: 6.2
import PackageDescription

// EkkoCore is the Swift port of src/core/*.ts. It is a package (not just a framework target)
// so the wire-compat tests can run on the Mac with `swift test`, without a simulator.
//
// ponytail: zero dependencies. CryptoKit on the iOS 26 / macOS 26 SDK ships MLKEM768 with a
// seed-based initializer that is byte-identical to @noble/post-quantum, so the whole hybrid
// handshake is stdlib. If we ever need to support iOS < 26, swap CryptoKit's MLKEM768 for
// apple/swift-crypto's — same type name, one SPM line.
let package = Package(
    name: "EkkoCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "EkkoCore", targets: ["EkkoCore"])
    ],
    targets: [
        .target(name: "EkkoCore"),
        .testTarget(name: "EkkoCoreTests", dependencies: ["EkkoCore"]),
    ]
)
