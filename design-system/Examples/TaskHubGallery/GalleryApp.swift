//
//  GalleryApp.swift
//  TaskHubGallery
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import SwiftUI
import TaskHubDesignSystem

struct GalleryOptions {
    let dark = ProcessInfo.processInfo.arguments.contains("--gallery-dark")
    let largeText = ProcessInfo.processInfo.arguments.contains("--gallery-accessibility")
    let narrow = ProcessInfo.processInfo.arguments.contains("--gallery-narrow")
}

@main
struct TaskHubGalleryApp: App {
    private let options = GalleryOptions()

    var body: some Scene {
        WindowGroup {
            GalleryAppearance(options: options)
                #if os(macOS)
                .frame(minWidth: 360, minHeight: 500)
                #endif
        }
        .defaultSize(width: options.narrow ? 430 : 1_160, height: 840)
    }
}

private struct GalleryAppearance: View {
    let options: GalleryOptions
    @Environment(\.dynamicTypeSize) private var systemTextSize

    var body: some View {
        GalleryView(options: options)
            .tint(HubColor.accent)
            .preferredColorScheme(options.dark ? .dark : nil)
            .dynamicTypeSize(options.largeText ? .accessibility5 : systemTextSize)
    }
}
