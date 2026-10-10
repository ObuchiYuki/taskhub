//
//  BrowseView.swift
//  TaskHub
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import SwiftUI
import TaskHubCore
import TaskHubDesignSystem

struct BrowseView: View {
    enum Kind { case tasks, decisions }
    let kind: Kind
    @EnvironmentObject private var store: AppStore
    @Binding var filter: BrowseFilter
    @State private var showFilters = false

    private var title: String { kind == .tasks ? "タスク" : "ユーザー裁定" }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            List {
                SyncHeader()
                Section {
                    HubSearchField(text: $filter.query, prompt: "タイトル・本文・追記・添付を検索")
                        .submitLabel(.search)
                        .onSubmit { dismissKeyboard() }
                    if let snapshot = store.snapshot {
                        Picker("レーン", selection: $filter.laneID) {
                            Text("すべてのレーン").tag(String?.none)
                            ForEach(snapshot.lanes) { lane in Text(verbatim: lane.name).tag(Optional(lane.id)) }
                        }
                        .accessibilityIdentifier("lane-filter")
                    }
                    HStack {
                        Text(statusDescription).font(HubTypography.caption).foregroundStyle(HubColor.secondaryText)
                        Spacer()
                        Button("絞り込み", systemImage: "line.3.horizontal.decrease") { showFilters = true }
                            .frame(minHeight: HubMetrics.minimumTarget)
                    }
                }
                if let snapshot = store.snapshot {
                    if kind == .tasks {
                        let tasks = snapshot.filteredTasks(filter)
                        Section("\(tasks.count)件") {
                            ForEach(tasks) { task in
                                NavigationLink(value: DetailRoute.task(task.id)) {
                                    HubTaskRow(task: snapshot.displayTask(task), now: context.date)
                                }
                                .accessibilityIdentifier("task-\(task.id)")
                                .accessibilityHint("タスク詳細を開く")
                            }
                            if tasks.isEmpty { emptyState }
                        }
                    } else {
                        let decisions = snapshot.filteredDecisions(filter)
                        Section("\(decisions.count)件・レーン横断で確認") {
                            ForEach(decisions) { decision in
                                NavigationLink(value: DetailRoute.decision(decision.id)) {
                                    HubDecisionCard(decision: snapshot.displayDecision(decision), now: context.date)
                                }
                                .listRowBackground(Color.clear)
                                .accessibilityIdentifier("decision-\(decision.id)")
                                .accessibilityHint("裁定詳細と回答記録を開く")
                            }
                            if decisions.isEmpty { emptyState }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(HubColor.canvas)
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await store.synchronize() }
            .navigationTitle(title)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("キーボードを閉じる") { dismissKeyboard() }
                }
                if store.cached?.configuration != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("同期", systemImage: "arrow.clockwise") { Task { await store.synchronize() } }
                            .disabled(store.isBusy)
                    }
                }
            }
        }
        .sheet(isPresented: $showFilters) {
            FilterView(filter: $filter, kind: kind)
                .environmentObject(store)
        }
    }

    private var statusDescription: String {
        let state = kind == .tasks ? filter.taskStatus?.display.title : filter.decisionStatus?.display.title
        var labels = [state ?? "全状態"]
        if let assignee = filter.assignee { labels.append(assignee) }
        if filter.since != nil || filter.until != nil { labels.append("期間指定あり") }
        return labels.joined(separator: "・")
    }

    private var emptyState: some View {
        HubEmptyState(title: "一致する項目なし", message: "検索語や絞り込み条件を変更してください。", actionTitle: "条件を解除") {
            filter = BrowseFilter()
        }
    }
}

struct FilterView: View {
    @Binding var filter: BrowseFilter
    let kind: BrowseView.Kind
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var since = Date(timeIntervalSinceNow: -7 * 86_400)
    @State private var until = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section("状態") {
                    if kind == .tasks {
                        Picker("タスク状態", selection: $filter.taskStatus) {
                            Text("全状態").tag(TaskStatus?.none)
                            ForEach(TaskStatus.allCases, id: \.self) { value in
                                Text(value.display.title).tag(Optional(value))
                            }
                        }
                    } else {
                        Picker("裁定状態", selection: $filter.decisionStatus) {
                            Text("全状態").tag(DecisionStatus?.none)
                            ForEach(DecisionStatus.allCases, id: \.self) { value in
                                Text(value.display.title).tag(Optional(value))
                            }
                        }
                        .accessibilityIdentifier("decision-status-filter")
                    }
                    Picker("担当", selection: $filter.assignee) {
                        Text("すべての担当").tag(String?.none)
                        ForEach(Array(Set(store.snapshot?.tasks.compactMap(\.assignee) ?? [])).sorted(), id: \.self) { value in
                            Text(verbatim: value).tag(Optional(value))
                        }
                    }
                }
                Section {
                    Toggle("開始日時を指定", isOn: Binding(get: { filter.since != nil }, set: { filter.since = $0 ? since : nil }))
                    if filter.since != nil {
                        DatePicker("開始（含む）", selection: $since).onChange(of: since) { _, value in filter.since = value }
                    }
                    Toggle("終了日時を指定", isOn: Binding(get: { filter.until != nil }, set: { filter.until = $0 ? until : nil }))
                    if filter.until != nil {
                        DatePicker("終了（含まない）", selection: $until).onChange(of: until) { _, value in filter.until = value }
                    }
                    if let start = filter.since, let end = filter.until, start >= end {
                        Text("終了日時を開始日時より後に設定してください。").foregroundStyle(HubColor.danger)
                    }
                } header: { Text("最終更新日時") } footer: {
                    Text("端末のタイムゾーンで表示。裁定の担当は元タスクの担当を使います。")
                }
                HubButton(title: "すべての条件を解除", role: .secondary) { filter = BrowseFilter() }
            }
            .navigationTitle("絞り込み")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { dismiss() } } }
            .onAppear {
                since = filter.since ?? since
                until = filter.until ?? until
            }
        }
        .hubTheme()
    }
}
