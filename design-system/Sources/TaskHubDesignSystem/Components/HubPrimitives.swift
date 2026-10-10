//
//  HubPrimitives.swift
//  TaskHubDesignSystem
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import SwiftUI

public struct HubBadge: View {
    public let title: String
    public let systemImage: String
    public let tone: HubTone

    public init(title: String, systemImage: String, tone: HubTone = .neutral) {
        self.title = title
        self.systemImage = systemImage
        self.tone = tone
    }

    public var body: some View {
        Label { Text(verbatim: title) } icon: { Image(systemName: systemImage) }
            .font(HubTypography.caption.weight(.semibold))
            .foregroundStyle(tone.color)
            .padding(.horizontal, HubSpacing.xs)
            .padding(.vertical, HubSpacing.xxs)
            .background(HubColor.surface, in: RoundedRectangle(cornerRadius: HubRadius.small))
            .overlay {
                RoundedRectangle(cornerRadius: HubRadius.small)
                    .strokeBorder(tone.color, lineWidth: 1)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }
}

public struct HubCard<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(HubSpacing.md)
            .background(HubColor.surface, in: RoundedRectangle(cornerRadius: HubRadius.large))
            .overlay {
                RoundedRectangle(cornerRadius: HubRadius.large)
                    .strokeBorder(HubColor.separator, lineWidth: 1)
            }
    }
}

public struct HubMetadata: View {
    public let label: String
    public let value: String
    public let systemImage: String?

    public init(label: String, value: String, systemImage: String? = nil) {
        self.label = label
        self.value = value
        self.systemImage = systemImage
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: HubSpacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: HubSpacing.xxs) {
                Text(verbatim: label).font(HubTypography.caption)
                Text(verbatim: value).font(HubTypography.callout).foregroundStyle(HubColor.text)
            }
        }
        .foregroundStyle(HubColor.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(label)、\(value)"))
    }
}

public struct HubDueLabel: View {
    public let date: Date?
    public let now: Date
    public let isResolved: Bool
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    public init(date: Date?, now: Date = Date(), isResolved: Bool = false) {
        self.date = date
        self.now = now
        self.isResolved = isResolved
    }

    private var state: HubDueState {
        .classify(date: date, now: now, isResolved: isResolved)
    }

    private var tone: HubTone {
        switch state {
        case .overdue: .danger
        case .dueSoon: .warning
        case .unspecified, .scheduled, .resolved: .neutral
        }
    }

    private var label: String {
        guard let date else { return state.title }
        let format = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, timeZone: timeZone)
        return "\(state.title)：\(date.formatted(format))"
    }

    public var body: some View {
        Label { Text(verbatim: label) } icon: { Image(systemName: state.systemImage) }
            .font(HubTypography.caption)
            .foregroundStyle(tone.color)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }
}
