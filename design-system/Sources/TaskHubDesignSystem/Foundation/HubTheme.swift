//
//  HubTheme.swift
//  TaskHubDesignSystem
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

public enum HubColor {
    public static let canvas = color(.canvas)
    public static let surface = color(.surface)
    public static let elevatedSurface = color(.elevatedSurface)
    public static let text = color(.text)
    public static let secondaryText = color(.secondaryText)
    public static let separator = color(.separator)
    public static let accent = color(.accent)
    public static let onAccent = color(.onAccent)
    public static let success = color(.success)
    public static let warning = color(.warning)
    public static let danger = color(.danger)
    public static let info = color(.info)

    public static func color(_ role: HubColorRole) -> Color {
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [
                .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua
            ])
            let dark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
            let contrast = match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
            let rgb = role.resolved(for: dark ? .dark : .light, increasedContrast: contrast)
            return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        })
        #else
        return Color(uiColor: UIColor { traits in
            let rgb = role.resolved(
                for: traits.userInterfaceStyle == .dark ? .dark : .light,
                increasedContrast: traits.accessibilityContrast == .high
            )
            return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        })
        #endif
    }
}

public enum HubSpacing {
    public static let xxs: CGFloat = 4
    public static let xs: CGFloat = 8
    public static let sm: CGFloat = 12
    public static let md: CGFloat = 16
    public static let lg: CGFloat = 24
    public static let xl: CGFloat = 32
    public static let xxl: CGFloat = 48
}

public enum HubRadius {
    public static let small: CGFloat = 8
    public static let medium: CGFloat = 12
    public static let large: CGFloat = 16
}

public enum HubMetrics {
    public static let minimumTarget: CGFloat = 44
    public static let readingWidth: CGFloat = 720
    public static let sidebarMinimumWidth: CGFloat = 220
}

/// System text styles retain Dynamic Type and platform-specific font metrics.
public enum HubTypography {
    public static let largeTitle: Font = .largeTitle.weight(.bold)
    public static let title: Font = .title2.weight(.bold)
    public static let headline: Font = .headline
    public static let body: Font = .body
    public static let callout: Font = .callout
    public static let caption: Font = .caption
    public static let identifier: Font = .caption.monospaced()
}

public enum HubTone: CaseIterable, Sendable {
    case neutral, accent, info, success, warning, danger

    public var color: Color {
        switch self {
        case .neutral: HubColor.secondaryText
        case .accent: HubColor.accent
        case .info: HubColor.info
        case .success: HubColor.success
        case .warning: HubColor.warning
        case .danger: HubColor.danger
        }
    }
}

public extension View {
    /// Apply once at the app's content root. The system appearance remains user-controlled.
    func hubTheme() -> some View {
        self
            .font(HubTypography.body)
            .foregroundStyle(HubColor.text)
            .tint(HubColor.accent)
    }
}
