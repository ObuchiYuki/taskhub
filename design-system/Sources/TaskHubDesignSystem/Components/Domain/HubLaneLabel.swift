//
//  HubLaneLabel.swift
//  TaskHubDesignSystem
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import SwiftUI

/// レーン名を省略せず表示する読み取り専用ラベル。
public struct HubLaneLabel: View {
    public let lane: HubLane

    public init(lane: HubLane) {
        self.lane = lane
    }

    public var body: some View {
        Label {
            Text(verbatim: lane.name)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "rectangle.3.group")
                .accessibilityHidden(true)
        }
        .font(HubTypography.caption)
        .foregroundStyle(HubColor.secondaryText)
        .multilineTextAlignment(.leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("レーン \(lane.name)"))
    }
}
