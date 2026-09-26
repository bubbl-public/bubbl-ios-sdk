// swift-tools-version: 6.0
//
// This file becomes Package.swift at the root of the public mirror, bubbl-public/bubbl-ios-sdk
// (the release's sync script copies it there, with ios/Sources as Sources/). It's how apps add
// Bubbl: in Xcode, File > Add Package Dependencies…, https://github.com/bubbl-public/bubbl-ios-sdk,
// product BubblSDK (and BubblNotificationService for an optional notification service extension).
// The product names are the install guide's: keep them. The private repo's ios/Package.swift is the
// one for building and testing (it also builds the core on Windows and Linux).
import PackageDescription

let package = Package(
    name: "BubblSDK",
    // Apps supporting iOS 13 and later can include Bubbl; it works on iOS 17 and later and does
    // nothing below (Bubbl.isSupported). 13 is as low as Swift concurrency goes.
    platforms: [.iOS(.v13), .macOS(.v14)],
    products: [
        .library(name: "BubblSDK", targets: ["BubblSDK"]),
        .library(name: "BubblNotificationService", targets: ["BubblNotificationService"]),
    ],
    targets: [
        .target(name: "BubblCore", path: "Sources/BubblCore"),
        .target(name: "BubblLaunch", path: "Sources/BubblLaunch"),
        .target(
            name: "BubblSDK",
            dependencies: ["BubblCore", "BubblLaunch"],
            path: "Sources/BubblSDK",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .target(name: "BubblNotificationService", dependencies: ["BubblCore"], path: "Sources/BubblNotificationService"),
    ]
)
