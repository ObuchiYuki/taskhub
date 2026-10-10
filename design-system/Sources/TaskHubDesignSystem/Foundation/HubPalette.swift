//
//  HubPalette.swift
//  TaskHubDesignSystem
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import Foundation

public enum HubAppearance: CaseIterable, Sendable {
    case light, dark
}

/// An opaque sRGB color, independent of a rendering framework.
public struct HubRGB: Equatable, Sendable {
    public let hex: UInt32

    public init(hex: UInt32) {
        self.hex = hex & 0xFFFFFF
    }

    public var red: Double { Double((hex >> 16) & 0xFF) / 255 }
    public var green: Double { Double((hex >> 8) & 0xFF) / 255 }
    public var blue: Double { Double(hex & 0xFF) / 255 }

    public var relativeLuminance: Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    public func contrastRatio(against other: HubRGB) -> Double {
        let a = relativeLuminance
        let b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// Semantic roles shared by both platforms. Use HubColor in SwiftUI.
public enum HubColorRole: CaseIterable, Sendable {
    case canvas, surface, elevatedSurface
    case text, secondaryText, separator
    case accent, onAccent, success, warning, danger, info

    public func resolved(for appearance: HubAppearance, increasedContrast: Bool = false) -> HubRGB {
        let value: UInt32
        switch (self, appearance) {
        case (.canvas, .light): value = 0xF4F6FA
        case (.canvas, .dark): value = 0x10151E
        case (.surface, .light): value = 0xFFFFFF
        case (.surface, .dark): value = 0x1A2230
        case (.elevatedSurface, .light): value = 0xEBEFF6
        case (.elevatedSurface, .dark): value = 0x252F40
        case (.text, .light): value = 0x182234
        case (.text, .dark): value = 0xF3F6FC
        case (.secondaryText, .light): value = increasedContrast ? 0x283345 : 0x526078
        case (.secondaryText, .dark): value = increasedContrast ? 0xE1E8F5 : 0xB2BED1
        case (.separator, .light): value = increasedContrast ? 0x526078 : 0x7D899D
        case (.separator, .dark): value = increasedContrast ? 0xB2BED1 : 0x73839A
        case (.accent, .light): value = 0x2455C7
        case (.accent, .dark): value = 0xAAC4FF
        case (.onAccent, .light): value = 0xFFFFFF
        case (.onAccent, .dark): value = 0x10213F
        case (.success, .light): value = 0x176342
        case (.success, .dark): value = 0x70DAA7
        case (.warning, .light): value = 0x805000
        case (.warning, .dark): value = 0xF6C86C
        case (.danger, .light): value = 0xAC2925
        case (.danger, .dark): value = 0xFFAAA5
        case (.info, .light): value = 0x165F91
        case (.info, .dark): value = 0x8BD0FF
        }
        return HubRGB(hex: value)
    }
}
