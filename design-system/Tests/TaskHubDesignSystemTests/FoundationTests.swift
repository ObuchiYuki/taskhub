//
//  FoundationTests.swift
//  TaskHubDesignSystemTests
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import XCTest
@testable import TaskHubDesignSystem

final class FoundationTests: XCTestCase {
    func testTextContrastInEveryAppearance() {
        let foregrounds: [HubColorRole] = [.text, .secondaryText, .accent, .success, .warning, .danger, .info]
        let backgrounds: [HubColorRole] = [.canvas, .surface, .elevatedSurface]
        for appearance in HubAppearance.allCases {
            for highContrast in [false, true] {
                for foreground in foregrounds {
                    for background in backgrounds {
                        let ratio = foreground.resolved(for: appearance, increasedContrast: highContrast)
                            .contrastRatio(against: background.resolved(for: appearance, increasedContrast: highContrast))
                        XCTAssertGreaterThanOrEqual(ratio, 4.5,
                            "\(foreground) on \(background), \(appearance), highContrast=\(highContrast): \(ratio)")
                    }
                }
                let ratio = HubColorRole.onAccent.resolved(for: appearance)
                    .contrastRatio(against: HubColorRole.accent.resolved(for: appearance))
                XCTAssertGreaterThanOrEqual(ratio, 4.5)
            }
        }
    }

    func testControlBorderContrast() {
        for appearance in HubAppearance.allCases {
            for background in [HubColorRole.canvas, .surface, .elevatedSurface] {
                let ratio = HubColorRole.separator.resolved(for: appearance)
                    .contrastRatio(against: background.resolved(for: appearance))
                XCTAssertGreaterThanOrEqual(ratio, 3, "\(appearance) \(background): \(ratio)")
            }
        }
    }

    func testSRGBLuminanceAndContrast() {
        let white = HubRGB(hex: 0xFFFFFF)
        let black = HubRGB(hex: 0)
        XCTAssertEqual(white.relativeLuminance, 1, accuracy: 0.0001)
        XCTAssertEqual(black.relativeLuminance, 0, accuracy: 0.0001)
        XCTAssertEqual(white.contrastRatio(against: black), 21, accuracy: 0.0001)
        XCTAssertEqual(black.contrastRatio(against: white), 21, accuracy: 0.0001)
        XCTAssertEqual(HubRGB(hex: 0xFF123456), HubRGB(hex: 0x123456))
    }

    func testDueDateBoundaries() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(HubDueState.classify(date: nil, now: now), .unspecified)
        XCTAssertEqual(HubDueState.classify(date: now.addingTimeInterval(-1), now: now), .overdue)
        XCTAssertEqual(HubDueState.classify(date: now, now: now), .dueSoon)
        XCTAssertEqual(HubDueState.classify(date: now.addingTimeInterval(86_400), now: now), .dueSoon)
        XCTAssertEqual(HubDueState.classify(date: now.addingTimeInterval(86_401), now: now), .scheduled)
        XCTAssertEqual(HubDueState.classify(date: now.addingTimeInterval(-1), now: now, isResolved: true), .resolved)
        XCTAssertEqual(HubDueState.classify(date: nil, now: now, isResolved: true), .unspecified)
        XCTAssertEqual(HubDueState.classify(date: now.addingTimeInterval(1), now: now, warningInterval: -1), .scheduled)
    }

    func testRetryAvailability() {
        XCTAssertFalse(HubSyncState.synced(lastUpdated: nil).canRetry)
        XCTAssertFalse(HubSyncState.syncing.canRetry)
        XCTAssertTrue(HubSyncState.offline(lastUpdated: nil).canRetry)
        XCTAssertTrue(HubSyncState.failed(message: "通信エラー").canRetry)
    }

    func testTokenScaleAndTargets() {
        XCTAssertEqual([HubSpacing.xxs, HubSpacing.xs, HubSpacing.sm, HubSpacing.md,
                        HubSpacing.lg, HubSpacing.xl, HubSpacing.xxl], [4, 8, 12, 16, 24, 32, 48])
        XCTAssertGreaterThanOrEqual(HubMetrics.minimumTarget, 44)
    }
}
