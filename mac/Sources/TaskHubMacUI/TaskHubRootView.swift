//
//  TaskHubRootView.swift
//  TaskHubMac
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import AppKit
import SwiftUI
import TaskHubDesignSystem
import TaskHubMacCore

private enum HubSection: String, CaseIterable, Identifiable {
    case decisions = "ユーザー裁定", tasks = "タスク", digest = "ダイジェスト", history = "変更履歴"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .decisions: "person.crop.circle.badge.questionmark"
        case .tasks: "checklist"
        case .digest: "text.alignleft"
        case .history: "clock.arrow.circlepath"
        }
    }
}

private struct Filters {
    var text = ""
    var laneID = ""
    var status = ""
    var assignee = ""
    var dateEnabled = false
    var since = Calendar.current.date(byAdding: .day, value: -30, to: .now)!
    var until = Date.now
}

public struct TaskHubRootView: View {
    private let store: HubStore
    private let initialSource: SourceConfiguration?
    @State private var section: HubSection = .decisions
    @State private var taskFilters = Filters()
    @State private var decisionFilters = Filters(status: "pending")
    @State private var selectedTask: String?
    @State private var selectedDecision: String?
    @State private var showsConnection = false
    @State private var showsFilters = false

    public init(store: HubStore, initialSource: SourceConfiguration? = nil) {
        self.store = store
        self.initialSource = initialSource
    }

    public var body: some View {
        VStack(spacing: 0) {
            if store.configuration != nil || store.isSyncing {
                HubSyncBanner(state: syncState, retry: { Task { await store.synchronize() } })
                    .padding(.horizontal, HubSpacing.md).padding(.vertical, HubSpacing.xs)
                    .accessibilityIdentifier("sync.banner")
                if store.cacheWasLoaded {
                    Text("保存済みデータを表示中。同期すると最新状態を確認できる。")
                        .font(HubTypography.caption).foregroundStyle(HubColor.secondaryText)
                }
            }
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
            } detail: {
                if let snapshot = store.snapshot {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        content(snapshot: snapshot, now: context.date)
                    }
                } else if store.isSyncing {
                    HubLoadingState()
                } else if let message = store.errorMessage {
                    HubErrorState(title: "データを読み込めない", message: message,
                                  retry: { showsConnection = true })
                } else {
                    HubEmptyState(title: "TaskHubへようこそ", message: "同期元を設定すると、タスクとユーザー裁定を確認できる。",
                        systemImage: "tray", actionTitle: "同期元を設定", action: { showsConnection = true })
                }
            }
        }
        .background(HubColor.canvas).hubTheme()
        .toolbar {
            ToolbarItemGroup {
                Button { Task { await store.synchronize() } } label: {
                    Label("今すぐ同期", systemImage: "arrow.triangle.2.circlepath")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(store.configuration == nil || store.isSyncing)
                .help("今すぐ同期（⌘R）").accessibilityIdentifier("sync.refresh")
                Button { showsConnection = true } label: {
                    Label("同期元を設定", systemImage: "gearshape").frame(minWidth: 44, minHeight: 44)
                }.accessibilityIdentifier("connection.open")
            }
        }
        .sheet(isPresented: $showsConnection) { ConnectionView(store: store) }
        .task {
            await store.synchronize(using: initialSource)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
                await store.synchronize()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await store.synchronize() }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            Task { await store.synchronize() }
        }
        .onChange(of: store.configuration) { _, _ in
            selectedTask = nil
            selectedDecision = nil
            taskFilters = Filters()
            decisionFilters = Filters(status: "pending")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                Section("TaskHub") {
                    ForEach(HubSection.allCases) { item in
                        Button {
                            section = item
                        } label: {
                            HStack {
                                Label(item.rawValue, systemImage: item.symbol)
                                Spacer(minLength: 0)
                                if item == .decisions, let count = store.snapshot?.decisions.filter({ $0.status == .pending }).count {
                                    Text("\(count)").font(HubTypography.caption).monospacedDigit()
                                }
                            }
                            .frame(minHeight: HubMetrics.minimumTarget)
                            .padding(.horizontal, HubSpacing.xs)
                            .background(section == item ? HubColor.elevatedSurface : .clear,
                                        in: RoundedRectangle(cornerRadius: HubRadius.small))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(section == item ? .isSelected : [])
                        .accessibilityIdentifier("section.\(item == .tasks ? "tasks" : item == .decisions ? "decisions" : item == .digest ? "digest" : "history")")
                    }
                }
            }
            VStack(alignment: .leading, spacing: HubSpacing.xs) {
                HubBadge(title: "読み取り専用", systemImage: "lock", tone: .neutral)
                Text(verbatim: store.configuration?.displayName ?? "同期元を設定してください")
                    .font(HubTypography.caption).foregroundStyle(HubColor.secondaryText)
                    .lineLimit(4)
                if let revision = store.revision {
                    Text("取得版 \(revision.prefix(12))").font(HubTypography.identifier)
                        .foregroundStyle(HubColor.secondaryText)
                }
                Text("起動中60秒ごと・復帰時に同期")
                    .font(HubTypography.caption).foregroundStyle(HubColor.secondaryText)
            }.padding(HubSpacing.md)
        }
    }

    private var syncState: HubSyncState {
        if store.isSyncing { return .syncing }
        if store.isOffline { return .offline(lastUpdated: store.lastUpdated) }
        if let message = store.errorMessage { return .failed(message: message) }
        return .synced(lastUpdated: store.lastUpdated)
    }

    @ViewBuilder private func content(snapshot: Snapshot, now: Date) -> some View {
        switch section {
        case .tasks, .decisions:
            HSplitView {
                collection(snapshot: snapshot, now: now)
                    .frame(minWidth: 290, idealWidth: 400, maxWidth: 520)
                detail(snapshot: snapshot, now: now).frame(minWidth: 340, maxWidth: .infinity)
            }
        case .digest:
            DigestView(snapshot: snapshot, now: now, navigate: navigate)
        case .history:
            if let context = try? store.auditContext() {
                HistoryView(context: context).id(store.sourceIdentity)
            }
        }
    }

    private var activeFilters: Binding<Filters> {
        section == .tasks ? $taskFilters : $decisionFilters
    }

    private func collection(snapshot: Snapshot, now: Date) -> some View {
        let filters = activeFilters.wrappedValue
        let query = SnapshotQuery(snapshot: snapshot)
        let laneID = filters.laneID.isEmpty ? nil : filters.laneID
        let assignee = filters.assignee.isEmpty ? nil : filters.assignee
        let since = filters.dateEnabled ? Calendar.current.startOfDay(for: filters.since) : nil
        let until = filters.dateEnabled ? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: filters.until)) : nil
        let taskStatuses: Set<TaskStatus> = TaskStatus(rawValue: filters.status).map { [$0] } ?? []
        let decisionStatuses: Set<DecisionStatus> = filters.status == "open" ? [.pending, .answered]
            : DecisionStatus(rawValue: filters.status).map { [$0] } ?? []
        let tasks = query.tasks(matching: TaskFilter(text: filters.text, laneID: laneID, statuses: taskStatuses,
            assignee: assignee, updatedSince: since, updatedUntil: until)).map(\.task)
        let decisions = query.decisions(matching: DecisionFilter(text: filters.text, laneID: laneID, statuses: decisionStatuses,
            assignee: assignee, updatedSince: since, updatedUntil: until)).map(\.decision)
        return VStack(alignment: .leading, spacing: HubSpacing.sm) {
            HStack {
                Heading(title: section.rawValue)
                Spacer()
                Button { showsFilters.toggle() } label: {
                    Label("絞り込み", systemImage: "line.3.horizontal.decrease")
                        .frame(minWidth: 44, minHeight: 44)
                }.buttonStyle(.plain).accessibilityIdentifier("filters.toggle")
            }
            .padding(.horizontal, HubSpacing.md)
            HubSearchField(text: activeFilters.text, prompt: "本文・追記・添付を検索")
                .padding(.horizontal, HubSpacing.md).accessibilityIdentifier("search.field")
            if showsFilters { filterControls(snapshot: snapshot) }
            let count = section == .tasks ? tasks.count : decisions.count
            Text("\(count) 件 · \(filters.laneID.isEmpty ? "全レーン" : snapshot.lane(filters.laneID).name)\(filters.status.isEmpty ? "" : " · 状態指定")")
                .font(HubTypography.caption).foregroundStyle(HubColor.secondaryText)
                .padding(.horizontal, HubSpacing.md).accessibilityIdentifier("results.count")
            if filters.dateEnabled && Calendar.current.startOfDay(for: filters.since) > Calendar.current.startOfDay(for: filters.until) {
                HubErrorState(message: "期間の開始日は終了日以前に指定してください。")
            } else if count == 0 {
                HubEmptyState(title: "一致する項目なし", message: "検索・レーン・状態・期間・担当を確認してください。",
                    actionTitle: "条件を解除", action: {
                        if section == .tasks { taskFilters = Filters() } else { decisionFilters = Filters() }
                    })
            } else if section == .tasks {
                List(tasks, selection: $selectedTask) { task in
                    HubTaskRow(task: snapshot.summary(task), now: now).tag(task.id)
                        .accessibilityIdentifier("row.\(task.id)")
                }.listStyle(.plain)
            } else {
                List(decisions, selection: $selectedDecision) { decision in
                    HubDecisionCard(decision: snapshot.summary(decision), now: now).tag(decision.id)
                        .accessibilityIdentifier("row.\(decision.id)")
                }.listStyle(.plain)
            }
        }
        .padding(.top, HubSpacing.md).background(HubColor.surface)
    }

    private func filterControls(snapshot: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: HubSpacing.xs) {
            Picker("レーン", selection: activeFilters.laneID) {
                Text("全レーン").tag("")
                ForEach(snapshot.lanes) { lane in Text(verbatim: lane.name).tag(lane.id) }
            }.accessibilityIdentifier("filter.lane")
            Picker("状態", selection: activeFilters.status) {
                Text("すべて").tag("")
                if section == .tasks {
                    ForEach(TaskStatus.allCases, id: \.rawValue) { status in Text(verbatim: status.presentation.title).tag(status.rawValue) }
                } else {
                    Text("未反映（未対応・回答済み）").tag("open")
                    ForEach(DecisionStatus.allCases, id: \.rawValue) { status in Text(verbatim: status.presentation.title).tag(status.rawValue) }
                }
            }.accessibilityIdentifier("filter.status")
            Picker("担当", selection: activeFilters.assignee) {
                Text("全担当").tag("")
                ForEach(Array(Set(snapshot.tasks.compactMap(\.assignee))).sorted(), id: \.self) { assignee in
                    Text(verbatim: assignee).tag(assignee)
                }
            }.accessibilityIdentifier("filter.assignee")
            Toggle("更新期間を指定", isOn: activeFilters.dateEnabled).frame(minHeight: 44)
            if activeFilters.wrappedValue.dateEnabled {
                DatePicker("開始日", selection: activeFilters.since, displayedComponents: .date)
                DatePicker("終了日", selection: activeFilters.until, displayedComponents: .date)
                Text("端末の時間帯で終了日末まで").font(HubTypography.caption)
            }
        }
        .controlSize(.large).padding(.horizontal, HubSpacing.md)
    }

    @ViewBuilder private func detail(snapshot: Snapshot, now: Date) -> some View {
        if section == .tasks, let task = snapshot.tasks.first(where: { $0.id == selectedTask }) {
            TaskDetail(task: task, snapshot: snapshot, store: store, now: now, navigate: navigate).id(task.id)
        } else if section == .decisions, let decision = snapshot.decisions.first(where: { $0.id == selectedDecision }) {
            DecisionDetail(decision: decision, snapshot: snapshot, store: store, now: now, navigate: navigate).id(decision.id)
        } else {
            HubEmptyState(title: "項目を選択", message: "一覧から詳細を開いて、依頼・証拠・追記・添付を確認できる。", systemImage: "sidebar.left")
        }
    }

    private func navigate(_ id: String) {
        if id.hasPrefix("t_") { section = .tasks; taskFilters = Filters(); selectedTask = id }
        if id.hasPrefix("d_") { section = .decisions; decisionFilters = Filters(); selectedDecision = id }
    }
}

private struct DigestView: View {
    let snapshot: Snapshot
    let now: Date
    let navigate: (String) -> Void
    var body: some View {
        Page {
            Heading(title: "日本語ダイジェスト")
            Text("全レーンの同期済みデータを集計。期限間近は72時間以内、停滞は7日以上。")
                .foregroundStyle(HubColor.secondaryText)
            Text(verbatim: SnapshotQuery(snapshot: snapshot).digest(now: now).japaneseSummary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("digest.text")
            Heading(title: "未反映のユーザー裁定")
            ForEach(snapshot.decisions.filter { $0.status != .applied }) { decision in
                Button { navigate(decision.id) } label: { HubDecisionCard(decision: snapshot.summary(decision), now: now) }
                    .buttonStyle(.plain).accessibilityHint("裁定の詳細を開く")
            }
        }
    }
}
