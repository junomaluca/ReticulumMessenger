// SPDX-License-Identifier: MIT
// ReticulumMessenger — MainTabView.swift

import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            ConversationsListView()
                .tabItem {
                    Label("Messages", systemImage: "bubble.left.and.bubble.right")
                }
                .tag(0)
                .badge(totalUnread)

            MeshMapView()
                .tabItem {
                    Label("Map", systemImage: "map")
                }
                .tag(1)

            NetworkStatusView()
                .tabItem {
                    Label("Network", systemImage: "network")
                }
                .tag(2)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(3)
        }
        .tint(.accentColor)
    }

    private var totalUnread: Int {
        appState.conversations.reduce(0) { $0 + $1.unreadCount }
    }
}
