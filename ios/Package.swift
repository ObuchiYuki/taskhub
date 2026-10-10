// swift-tools-version: 6.0
//
//  Package.swift
//  TaskHubCore
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import PackageDescription

let package = Package(
    name: "TaskHubCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "TaskHubCore", targets: ["TaskHubCore"])],
    targets: [
        .target(name: "TaskHubCore"),
        .testTarget(name: "TaskHubCoreTests", dependencies: ["TaskHubCore"], resources: [.copy("Fixtures")])
    ]
)
