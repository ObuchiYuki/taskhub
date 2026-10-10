//
//  RootView.swift
//  TaskHub
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import SwiftUI
import TaskHubCore
import TaskHubDesignSystem

enum AppSection: String, CaseIterable, Identifiable {
    case decisions = "裁定", tasks = "タスク", digest = "整理", settings = "設定"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .decisions: "person.crop.circle.badge.questionmark"
        case .tasks: "checklist"
        case .digest: "text.badge.checkmark"
        case .settings: "gearshape"
        }
    }
}

enum DetailRoute: Hashable {
    case task(String), decision(String), attachment(String)
}

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var section: AppSection = .decisions
    @State private var taskFilter = BrowseFilter()
    @State private var decisionFilter: BrowseFilter = {
        var filter = BrowseFilter()
        filter.decisionStatus = .pending
        return filter
    }()
    @State private var paths: [AppSection: [DetailRoute]] = [:]
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        Group {
            if !store.restored {
                HubLoadingState()
            } else if store.snapshot == nil {
                NavigationStack { ConnectionView() }
            } else if sizeClass == .regular {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    List(AppSection.allCases) { item in
                        Button { section = item } label: {
                            Label(item.rawValue, systemImage: item.symbol)
                                .frame(maxWidth: .infinity, minHeight: HubMetrics.minimumTarget, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(section == item ? HubColor.accent : HubColor.text)
                        .listRowBackground(section == item ? HubColor.elevatedSurface : HubColor.surface)
                        .accessibilityAddTraits(section == item ? .isSelected : [])
                        .accessibilityIdentifier("section-\(item.rawValue)")
                    }
                    .navigationTitle("TaskHub")
                } detail: {
                    sectionView(section).id(section)
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                TabView(selection: $section) {
                    sectionView(.decisions)
                        .tabItem { Label("裁定", systemImage: AppSection.decisions.symbol) }
                        .badge(store.snapshot?.decisions.filter { $0.status == .pending }.count ?? 0)
                        .tag(AppSection.decisions)
                    sectionView(.tasks)
                        .tabItem { Label("タスク", systemImage: AppSection.tasks.symbol) }.tag(AppSection.tasks)
                    sectionView(.digest)
                        .tabItem { Label("整理", systemImage: AppSection.digest.symbol) }.tag(AppSection.digest)
                    sectionView(.settings)
                        .tabItem { Label("設定", systemImage: AppSection.settings.symbol) }.tag(AppSection.settings)
                }
            }
        }
        .id(store.sourceKey)
        .onChange(of: store.sourceKey) { _, _ in
            paths = [:]
            taskFilter = BrowseFilter()
            decisionFilter = BrowseFilter()
            decisionFilter.decisionStatus = .pending
        }
    }

    private func sectionView(_ section: AppSection) -> some View {
        NavigationStack(path: Binding(get: { paths[section] ?? [] }, set: {
            if self.section == section { paths[section] = $0 }
        })) {
            Group {
                switch section {
                case .decisions: BrowseView(kind: .decisions, filter: $decisionFilter)
                case .tasks: BrowseView(kind: .tasks, filter: $taskFilter)
                case .digest: DigestView()
                case .settings: ConnectionView()
                }
            }
            .navigationDestination(for: DetailRoute.self) { route in
                switch route {
                case .task(let id): TaskDetailView(id: id)
                case .decision(let id): DecisionDetailView(id: id)
                case .attachment(let id): AttachmentDetailView(id: id)
                }
            }
        }
    }
}

struct SyncHeader: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: HubSpacing.xs) {
            if store.isDemo {
                HubBadge(title: "サンプル・端末内のみ", systemImage: "iphone", tone: .info)
            } else if store.cached?.configuration == nil {
                HubBadge(title: "JSON読込・手動更新", systemImage: "doc", tone: .neutral)
            }
            if !store.isDemo {
                HubSyncBanner(state: store.syncState, retry: store.cached?.configuration == nil ? nil : {
                    Task { await store.synchronize() }
                })
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}
