//
//  HubControls.swift
//  TaskHubDesignSystem
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import SwiftUI

public enum HubButtonRole: CaseIterable, Sendable {
    case primary, secondary, destructive
}

/// A native button style that preserves keyboard and accessibility activation.
public struct HubButtonStyle: ButtonStyle {
    public let role: HubButtonRole
    @Environment(\.isEnabled) private var isEnabled

    public init(role: HubButtonRole = .primary) {
        self.role = role
    }

    private var foreground: Color {
        switch role {
        case .primary: HubColor.onAccent
        case .secondary: HubColor.accent
        case .destructive: HubColor.danger
        }
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(HubTypography.callout.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, HubSpacing.md)
            .padding(.vertical, HubSpacing.xs)
            .frame(minWidth: HubMetrics.minimumTarget, minHeight: HubMetrics.minimumTarget)
            .foregroundStyle(foreground)
            .background(role == .primary ? HubColor.accent : HubColor.surface,
                        in: RoundedRectangle(cornerRadius: HubRadius.medium))
            .overlay {
                RoundedRectangle(cornerRadius: HubRadius.medium)
                    .strokeBorder(role == .destructive ? HubColor.danger : HubColor.accent, lineWidth: 1)
            }
            .brightness(configuration.isPressed ? -0.08 : 0)
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: HubRadius.medium))
    }
}

public struct HubButton: View {
    public let title: String
    public let systemImage: String?
    public let role: HubButtonRole
    public let isLoading: Bool
    private let action: () -> Void

    public init(
        title: String,
        systemImage: String? = nil,
        role: HubButtonRole = .primary,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.isLoading = isLoading
        self.action = action
    }

    public var body: some View {
        Button(role: role == .destructive ? .destructive : nil, action: action) {
            HStack(spacing: HubSpacing.xs) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(role == .primary ? HubColor.onAccent : HubColor.accent)
                        .accessibilityHidden(true)
                } else if let systemImage {
                    Image(systemName: systemImage).accessibilityHidden(true)
                }
                Text(verbatim: title).fixedSize(horizontal: false, vertical: true)
            }
        }
        .buttonStyle(HubButtonStyle(role: role))
        .disabled(isLoading)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(isLoading ? Text("処理中") : Text(""))
    }
}

public struct HubSearchField: View {
    @Binding private var text: String
    public let prompt: String

    public init(text: Binding<String>, prompt: String = "タスク・裁定を検索") {
        self._text = text
        self.prompt = prompt
    }

    public var body: some View {
        HStack(spacing: HubSpacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(HubColor.secondaryText)
                .accessibilityHidden(true)
            TextField(text: $text, prompt: Text(verbatim: prompt)) {
                Text(verbatim: prompt)
            }
            .textFieldStyle(.plain)
            .accessibilityLabel(Text(verbatim: prompt))
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            #endif
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .frame(width: HubMetrics.minimumTarget, height: HubMetrics.minimumTarget)
                }
                .buttonStyle(.plain)
                .foregroundStyle(HubColor.secondaryText)
                .accessibilityLabel("検索をクリア")
            }
        }
        .padding(.leading, HubSpacing.sm)
        .padding(.trailing, text.isEmpty ? HubSpacing.sm : 0)
        .frame(minHeight: HubMetrics.minimumTarget)
        .background(HubColor.surface, in: RoundedRectangle(cornerRadius: HubRadius.medium))
        .overlay {
            RoundedRectangle(cornerRadius: HubRadius.medium)
                .strokeBorder(HubColor.separator, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

public struct HubFilterChip: View {
    public let title: String
    public let isSelected: Bool
    private let action: () -> Void

    public init(title: String, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: HubSpacing.xxs) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .accessibilityHidden(true)
                Text(verbatim: title).fixedSize(horizontal: false, vertical: true)
            }
        }
        .buttonStyle(HubButtonStyle(role: isSelected ? .primary : .secondary))
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(isSelected ? Text("選択中") : Text("未選択"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
