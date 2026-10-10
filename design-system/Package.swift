// swift-tools-version: 6.0
//
//  Package.swift
//  TaskHubDesignSystem
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import PackageDescription

let package = Package(
    name: "TaskHubDesignSystem",
    defaultLocalization: "ja",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "TaskHubDesignSystem", targets: ["TaskHubDesignSystem"])
    ],
    targets: [
        .target(name: "TaskHubDesignSystem"),
        .testTarget(name: "TaskHubDesignSystemTests", dependencies: ["TaskHubDesignSystem"])
    ]
)
