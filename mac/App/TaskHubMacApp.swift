//
//  TaskHubMacApp.swift
//  TaskHubMac
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import AppKit
import SwiftUI
import TaskHubMacCore
import TaskHubMacUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct TaskHubMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store: HubStore
    private let initialSource: SourceConfiguration?

    init() {
        var cache = SnapshotCache.applicationDefault
        var source: SourceConfiguration?
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["TASKHUB_TEST_CACHE"] {
            cache = SnapshotCache(directory: URL(fileURLWithPath: path, isDirectory: true))
            if let directory = environment["TASKHUB_TEST_SOURCE"] { source = .local(directory: directory) }
        }
        #endif
        _store = State(initialValue: HubStore(cache: cache))
        initialSource = source
    }

    var body: some Scene {
        Window("TaskHub", id: "main") {
            TaskHubRootView(store: store, initialSource: initialSource)
                .frame(minWidth: 960, minHeight: 640)
        }
        .defaultSize(width: 1_360, height: 880)
        .commands {
            CommandGroup(after: .newItem) {
                Button("今すぐ同期") { Task { await store.synchronize() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(store.configuration == nil || store.isSyncing)
            }
        }
    }
}
