// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "cloudflare_realtime",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "cloudflare-realtime", targets: ["cloudflare_realtime"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "cloudflare_realtime",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [
                // The privacy manifest (the plugin reads UserDefaults, a required reason API).
                // The podspec ships the same file as its cloudflare_realtime_privacy bundle.
                .process("PrivacyInfo.xcprivacy")
            ]
        )
    ]
)
