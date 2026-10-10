//
//  DigestView.swift
//  TaskHub
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import SwiftUI
import TaskHubCore
import TaskHubDesignSystem

struct DigestView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            List {
                SyncHeader()
                Section {
                    Text("全レーンの日本語ダイジェスト")
                        .font(HubTypography.headline)
                    Text("期限間近は72時間以内、停滞は7日以上更新なし。同じレーンの同名タスクを重複候補として表示します。")
                        .font(HubTypography.callout).foregroundStyle(HubColor.secondaryText)
                    Text("端末内で集計・\(formattedDate(context.date))")
                        .font(HubTypography.caption)
                }
                if let snapshot = store.snapshot {
                    ForEach(snapshot.digest(now: context.date)) { section in
                        Section(section.title) {
                            Text(verbatim: section.summary)
                            ForEach(items(in: section, snapshot: snapshot)) { item in
                                NavigationLink(value: item.route) {
                                    Label { Text(verbatim: item.title) } icon: { Image(systemName: item.symbol) }
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(HubColor.canvas)
            .refreshable { await store.synchronize() }
            .navigationTitle("整理")
        }
    }

    private func items(in section: DigestSection, snapshot: Snapshot) -> [DigestItem] {
        let tasks = section.taskIDs.compactMap { snapshot.task(id: $0) }.map {
            DigestItem(id: $0.id, title: $0.title, symbol: $0.status.display.systemImage, dueAt: $0.dueAt, route: .task($0.id))
        }
        let decisions = section.decisionIDs.compactMap { snapshot.decision(id: $0) }.map {
            DigestItem(id: $0.id, title: $0.title, symbol: $0.status.display.systemImage, dueAt: $0.dueAt, route: .decision($0.id))
        }
        return (tasks + decisions).sorted {
            switch ($0.dueAt, $1.dueAt) {
            case let (left?, right?) where left != right: return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.id < $1.id
            }
        }
    }
}

private struct DigestItem: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let dueAt: Date?
    let route: DetailRoute
}
