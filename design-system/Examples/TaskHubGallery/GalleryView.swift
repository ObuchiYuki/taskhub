//
//  GalleryView.swift
//  TaskHubGallery
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import SwiftUI
import TaskHubDesignSystem

enum GallerySection: String, CaseIterable, Identifiable {
    case tasks, decisions, components

    var id: String { rawValue }
    var title: String {
        switch self {
        case .tasks: "タスク"
        case .decisions: "ユーザー裁定"
        case .components: "部品一覧"
        }
    }
    var symbol: String {
        switch self {
        case .tasks: "checklist"
        case .decisions: "person.crop.circle.badge.questionmark"
        case .components: "square.grid.2x2"
        }
    }
}

enum GalleryRoute: Hashable {
    case task(String)
    case decision(String)
}

struct GalleryView: View {
    let options: GalleryOptions
    @State private var section: GallerySection? = .tasks
    @State private var visibility: NavigationSplitViewVisibility
    @State private var path: [GalleryRoute] = []
    @State private var search = ""
    @State private var laneID: String?
    @State private var decisions = GalleryData.decisions
    @State private var syncState = HubSyncState.synced(lastUpdated: GalleryData.now)

    init(options: GalleryOptions) {
        self.options = options
        _visibility = State(initialValue: options.narrow ? .detailOnly : .all)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            List(selection: $section) {
                Section("ギャラリー") {
                    ForEach(GallerySection.allCases) { item in
                        NavigationLink(value: item) {
                            Label(item.title, systemImage: item.symbol)
                        }
                        .accessibilityIdentifier("sidebar.\(item.id)")
                    }
                }
            }
            .navigationTitle("TaskHub")
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            NavigationStack(path: $path) {
                GalleryPage {
                    intro
                    HubSyncBanner(state: syncState)
                        .accessibilityIdentifier("gallery.sync.banner")
                    if syncState.canRetry {
                        HubButton(title: "同期を再試行", systemImage: "arrow.clockwise", role: .secondary) {
                            syncState = .synced(lastUpdated: GalleryData.now)
                        }
                        .accessibilityIdentifier("sync.retry")
                    }
                    switch section ?? .tasks {
                    case .tasks:
                        filters
                        taskList
                    case .decisions:
                        filters
                        decisionList
                    case .components:
                        GalleryComponents(syncState: $syncState)
                    }
                }
                .navigationTitle((section ?? .tasks).title)
                .toolbar { sectionMenu }
                .navigationDestination(for: GalleryRoute.self) { route in
                    switch route {
                    case .task(let id):
                        if let task = GalleryData.tasks.first(where: { $0.id == id }) {
                            GalleryTaskDetail(task: task, decisions: decisions.filter { $0.summary.taskID == id })
                        }
                    case .decision(let id):
                        if let decision = decisions.first(where: { $0.id == id }) {
                            GalleryDecisionDetail(decision: decision) { reply in
                                recordReply(reply, for: id)
                            }
                        }
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: section) { _, _ in path.removeAll() }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: HubSpacing.xs) {
            Text((section ?? .tasks).title)
                .font(HubTypography.largeTitle)
                .foregroundStyle(HubColor.text)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("gallery.section.title")
            Text("端末内のサンプルデータです。通信・認証・ファイル保存は行いません。")
                .font(HubTypography.caption)
                .foregroundStyle(HubColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if options.dark || options.largeText || options.narrow {
                Text([
                    options.dark ? "ダーク" : nil,
                    options.largeText ? "アクセシビリティ文字" : nil,
                    options.narrow ? "狭幅" : nil
                ].compactMap { $0 }.joined(separator: "・"))
                .font(HubTypography.caption)
                .accessibilityIdentifier("gallery.preview")
            }
        }
    }

    private var sectionMenu: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                ForEach(GallerySection.allCases) { item in
                    Button {
                        path.removeAll()
                        section = item
                    } label: {
                        Label(item.title, systemImage: item.symbol)
                    }
                    .accessibilityIdentifier("navigation.\(item.id)")
                }
            } label: {
                Label("表示するセクション", systemImage: "rectangle.3.group")
            }
            .accessibilityIdentifier("navigation.sections")
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: HubSpacing.sm) {
            HubSearchField(text: $search)
                .accessibilityIdentifier("gallery.search")
            ScrollView(.horizontal) {
                HStack(spacing: HubSpacing.xs) {
                    HubFilterChip(title: "すべて", isSelected: laneID == nil) { laneID = nil }
                        .accessibilityIdentifier("lane.all")
                    ForEach(GalleryData.lanes) { lane in
                        HubFilterChip(title: lane.name, isSelected: laneID == lane.id) { laneID = lane.id }
                            .accessibilityIdentifier("lane.\(lane.id)")
                    }
                }
                .padding(.vertical, HubSpacing.xxs)
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("gallery.lanes")
            Button("検索・絞り込みをリセット", action: resetFilters)
                .font(HubTypography.callout)
                .disabled(search.isEmpty && laneID == nil)
                .accessibilityIdentifier("filters.reset")
        }
    }

    private var filteredTasks: [GalleryTask] {
        GalleryData.tasks.filter { matches(text: $0.searchableText, lane: $0.summary.lane.id) }
    }

    private var filteredDecisions: [GalleryDecision] {
        decisions.filter { matches(text: $0.searchableText, lane: $0.summary.lane.id) }
    }

    private var taskList: some View {
        VStack(alignment: .leading, spacing: HubSpacing.sm) {
            resultCount(filteredTasks.count)
            if filteredTasks.isEmpty {
                emptySearch
            } else {
                ForEach(filteredTasks) { task in
                    NavigationLink(value: GalleryRoute.task(task.id)) {
                        HubCard {
                            HubTaskRow(task: task.summary, now: GalleryData.now)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("task.\(task.id)")
                    .accessibilityHint("タスクの本文、添付、履歴を表示")
                }
            }
        }
    }

    private var decisionList: some View {
        VStack(alignment: .leading, spacing: HubSpacing.sm) {
            resultCount(filteredDecisions.count)
            if filteredDecisions.isEmpty {
                emptySearch
            } else {
                ForEach(filteredDecisions) { decision in
                    NavigationLink(value: GalleryRoute.decision(decision.id)) {
                        HubDecisionCard(decision: decision.summary, now: GalleryData.now)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("decision.\(decision.id)")
                    .accessibilityHint("裁定の選択肢と回答を表示")
                }
            }
        }
    }

    private func resultCount(_ count: Int) -> some View {
        Text("\(count)件")
            .font(HubTypography.caption)
            .foregroundStyle(HubColor.secondaryText)
            .accessibilityIdentifier("gallery.resultCount")
    }

    private var emptySearch: some View {
        HubEmptyState(
            title: "一致する項目がありません", message: "別のキーワードを試すか、検索とレーンの絞り込みを解除してください。",
            systemImage: "magnifyingglass", actionTitle: "条件をリセット", action: resetFilters
        )
        .accessibilityIdentifier("gallery.empty")
    }

    private func matches(text: String, lane: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return (laneID == nil || laneID == lane) && (query.isEmpty || text.localizedStandardContains(query))
    }

    private func resetFilters() {
        search = ""
        laneID = nil
    }

    private func recordReply(_ reply: String, for id: String) {
        guard let index = decisions.firstIndex(where: { $0.id == id }),
              decisions[index].summary.status == .pending else { return }
        let previous = decisions[index].summary
        decisions[index].summary = HubDecisionSummary(
            id: previous.id, title: previous.title, taskID: previous.taskID, lane: previous.lane,
            status: .answered, options: previous.options, reason: previous.reason, dueDate: previous.dueDate,
            registeredBy: previous.registeredBy, registeredAt: previous.registeredAt, reply: reply
        )
        decisions[index].history.append(HubHistoryEntry(
            id: "local-reply-\(id)", actor: "Yuki（サンプル）", timestamp: GalleryData.now,
            message: "回答を記録：\(reply)"
        ))
    }
}

struct GalleryPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HubSpacing.lg) {
                content
            }
            .frame(maxWidth: 880, alignment: .leading)
            .padding(HubSpacing.md)
            .frame(maxWidth: .infinity)
        }
        .background(HubColor.canvas)
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("gallery.page")
    }
}

struct GalleryHeading: View {
    let title: String

    var body: some View {
        Text(title)
            .font(HubTypography.title)
            .foregroundStyle(HubColor.text)
            .accessibilityAddTraits(.isHeader)
    }
}
