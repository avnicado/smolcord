// swift-tools-version:5.5
//
//  Package.swift
//
//  A Linux-buildable subset of smolcord, so the portable logic can be tested
//  without a Mac.
//
//  This is NOT how the app is built. The app is an Xcode project generated from
//  project.yml, and it compiles every file in Sources/. This package compiles
//  only the files that import nothing Apple-specific, so `swift test` on Linux
//  can actually run them.
//
//  What this covers:
//
//    Protocol/   GatewayCapabilities, GatewayOpcode, GatewayEvent, Identify
//    Transport/  ByteMeter, ZlibInflater
//    Model/      Persistence
//    Support/    TextWrap
//
//  What it cannot cover, because the frameworks do not exist on Linux:
//
//    all of Sources/UI/        UIKit
//    WebSocketClient          Network.framework
//    Gateway, DMStore         depend on the above
//    Keychain                 Security.framework
//    REST                     depends on ByteMeter plus Apple URLSession
//                             behaviour worth testing on-device, not here
//
//  So a green `swift test` here means the wire-format parsing, the byte
//  accounting, the on-disk format and the text layout are correct. It says
//  nothing about whether the app builds or runs. Only the Xcode build does.
//
//  Usage:
//      swift build
//      swift test
//
//  The module is named `smolcord` so `@testable import smolcord` works
//  unchanged in both this package and the Xcode test target.

import PackageDescription

let package = Package(
    name: "smolcord",
    products: [
        .library(name: "smolcord", targets: ["smolcord"]),
    ],
    targets: [
        // System zlib. iOS gets the same shim through a bridging header.
        .systemLibrary(name: "CZlib", path: "Packaging/CZlib"),

        .target(
            name: "smolcord",
            dependencies: ["CZlib"],
            path: "Sources",
            // An explicit list, not a glob. Adding a file here is a claim that
            // it imports nothing Apple-specific, and the build will say so if
            // the claim is wrong.
            sources: [
                "Protocol/GatewayCapabilities.swift",
                "Protocol/GatewayOpcode.swift",
                "Protocol/GatewayEvent.swift",
                "Protocol/Identify.swift",
                "Transport/ByteMeter.swift",
                "Transport/ZlibInflater.swift",
                "Model/Persistence.swift",
                "Support/TextWrap.swift",
            ]
        ),

        .testTarget(
            name: "smolcordCoreTests",
            dependencies: ["smolcord"],
            path: "Tests/Core"
        ),
    ]
)
