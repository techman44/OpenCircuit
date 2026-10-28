// swift-tools-version: 5.9
import PackageDescription

// The `OpenCircuitKit` target holds the platform-agnostic core of the iOS app: the RingConn
// frame codec (ported from desktop/opencircuit/framing.py), metric models, and the openwhoop
// analytics port. That target imports only Foundation, NO other Apple framework, so it builds
// and tests with `swift test` on the command line, without Xcode or a device. The
// CoreBluetooth / HealthKit / SwiftData glue lives in the Xcode app target and imports it.
//
// The Zepp targets are not pure: `ZeppKit` imports CommonCrypto (AES) and Security (the
// CSPRNG), and the `HelioVerify` tool imports CoreBluetooth. The app links only the
// `OpenCircuitKit` product.
let package = Package(
    name: "OpenCircuitKit",
    platforms: [
        // The `HealthEgress` target's HealthKit surface needs the modern initializers; the app
        // is iOS 17+ anyway (ios/project.yml deploymentTarget), and `swift test` runs on macOS.
        .iOS("17.0"),
        .macOS("14.0"),
    ],
    products: [
        .library(name: "OpenCircuitKit", targets: ["OpenCircuitKit"]),
        .library(name: "ZeppKit", targets: ["ZeppKit"]),
        // Apple Health EGRESS (read + upload to the collector). Its own target, so the
        // `OpenCircuitKit` purity (Foundation-only, `swift test` anywhere) is untouched;
        // this one may import HealthKit/Security behind availability gates.
        .library(name: "HealthEgress", targets: ["HealthEgress"]),
        // Test-only: the simulated strap shared by ZeppKitTests and the app's OpenCircuitTests.
        .library(name: "ZeppKitTesting", targets: ["ZeppKitTesting"]),
    ],
    targets: [
        .target(name: "OpenCircuitKit"),
        .target(name: "HealthEgress"),
        // Batch-contract + anchor-rule tests with an injected fake URLSession and fake samples.
        // No test here needs a live HKHealthStore (that is why the reader sits behind
        // `HealthEgressReading`) — same stance as the existing suite's HK note.
        .testTarget(name: "HealthEgressTests", dependencies: ["HealthEgress"]),
        // `swift test` (needs Xcode for XCTest) runs this suite.
        .testTarget(
            name: "OpenCircuitKitTests",
            dependencies: ["OpenCircuitKit"],
            resources: [.process("Fixtures")]
        ),
        // CLT-friendly verifier: `swift run RingKitVerify` works without Xcode,
        // asserting the same real-capture fixtures. Stopgap until Xcode is present.
        .executableTarget(name: "RingKitVerify", dependencies: ["OpenCircuitKit"]),
        // Zepp OS (Amazfit Helio Strap) protocol core, #215. Built ONLY from docs/ZEPP_PROTOCOL.md
        // plus public standards; the B-163 maths is ported from public-domain tiny-ECDH-c. Pure
        // Swift + CommonCrypto (Security for the CSPRNG): no CoreBluetooth, no app code.
        .target(name: "ZeppKit", dependencies: ["OpenCircuitKit"]),
        // A simulated strap written from the spec (FakeZeppDevice), for tests only. Public ZeppKit
        // API only, so the app's test target can compile the same file (ios/project.yml).
        .target(name: "ZeppKitTesting", dependencies: ["ZeppKit"]),
        .testTarget(
            name: "ZeppKitTests",
            dependencies: ["ZeppKit", "OpenCircuitKit", "ZeppKitTesting"],
            exclude: ["make_b163_vectors.sh"]
        ),
        // macOS CoreBluetooth verifier for a real strap: `swift run HelioVerify --help`.
        // Thin BLE glue only; every decision lives in ZeppKit.
        .executableTarget(name: "HelioVerify", dependencies: ["ZeppKit"]),
        // HelioVerify's command-line parsing (write gating), without Bluetooth.
        .testTarget(name: "HelioVerifyTests", dependencies: ["HelioVerify"]),
    ]
)
