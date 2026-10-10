//
//  TaskHubApp.swift
//  TaskHub
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import SwiftUI
import TaskHubDesignSystem

@main
struct TaskHubApp: App {
    @StateObject private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .hubTheme()
                .labelStyle(.titleAndIcon)
                #if DEBUG
                .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--ui-dark") ? .dark : nil)
                #endif
                .task(id: scenePhase) {
                    await store.restore()
                    guard scenePhase == .active, store.automaticSyncEnabled else { return }
                    while !Task.isCancelled {
                        await store.synchronize()
                        do { try await Task.sleep(for: .seconds(60)) }
                        catch { return }
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { store.scheduleRefresh() }
                }
        }
        .backgroundTask(.appRefresh(AppStore.refreshIdentifier)) {
            await store.restore()
            await store.synchronize()
            await store.scheduleRefresh()
        }
    }
}
