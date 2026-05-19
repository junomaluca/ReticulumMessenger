// SPDX-License-Identifier: MIT
// ReticulumMessenger — ReticulumMessengerApp.swift

import SwiftUI

@main
struct ReticulumMessengerApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(appState)
                .task {
                    await appState.initialize()
                }
        }
    }
}
