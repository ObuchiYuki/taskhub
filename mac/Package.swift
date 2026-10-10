// swift-tools-version: 6.0
//
//  Package.swift
//  TaskHubMac
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import PackageDescription

let package = Package(
    name: "TaskHubMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TaskHubMacCore", targets: ["TaskHubMacCore"]),
        .library(name: "TaskHubMacUI", targets: ["TaskHubMacUI"])
    ],
    dependencies: [.package(path: "../design-system")],
    targets: [
        .target(name: "TaskHubMacCore"),
        .target(name: "TaskHubMacUI", dependencies: [
            "TaskHubMacCore", .product(name: "TaskHubDesignSystem", package: "design-system")
        ]),
        .testTarget(name: "TaskHubMacCoreTests", dependencies: ["TaskHubMacCore"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "TaskHubMacUITests", dependencies: ["TaskHubMacUI", "TaskHubMacCore"],
                    resources: [.copy("Fixtures")])
    ]
)
