// SPDX-License-Identifier: MIT
// ReticulumMessenger — AnnounceStreamView.swift
// Shows the stream of network announces as they arrive.

import SwiftUI

struct AnnounceStreamView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        List {
            if appState.announceStream.isEmpty {
                ContentUnavailableView {
                    Label("No Announces", systemImage: "megaphone")
                } description: {
                    Text("Network announces will appear here as peers broadcast their presence.")
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(appState.announceStream) { announce in
                    AnnounceRow(announce: announce)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Announce Stream")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    appState.announceStream.removeAll()
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(appState.announceStream.isEmpty)
            }
        }
    }
}

// MARK: - Announce Row

struct AnnounceRow: View {
    let announce: AnnounceEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: announceIcon)
                .font(.title3)
                .foregroundStyle(announceColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(announce.displayName ?? announce.shortHash)
                        .font(.subheadline.bold())
                    Spacer()
                    Text(announce.timestamp, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text(announce.hash)
                    .font(.caption2)
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let appData = announce.appData {
                    Text(appData)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button {
                UIPasteboard.general.string = announce.hash
            } label: {
                Label("Copy Hash", systemImage: "doc.on.doc")
            }

            if announce.type == .lxmf {
                Button {
                    // Start conversation action handled by parent
                } label: {
                    Label("Send Message", systemImage: "bubble.left")
                }
            }
        }
    }

    private var announceIcon: String {
        switch announce.type {
        case .lxmf: return "bubble.left.and.bubble.right"
        case .node: return "server.rack"
        case .transport: return "arrow.triangle.branch"
        case .unknown: return "questionmark.circle"
        }
    }

    private var announceColor: Color {
        switch announce.type {
        case .lxmf: return .accentColor
        case .node: return .green
        case .transport: return .orange
        case .unknown: return .secondary
        }
    }
}

// MARK: - AnnounceEntry Model

struct AnnounceEntry: Identifiable {
    let id = UUID()
    let hash: String
    let displayName: String?
    let type: AnnounceType
    let timestamp: Date
    let appData: String?
    let destinationHash: Data?

    var shortHash: String {
        String(hash.prefix(12)) + "…"
    }

    enum AnnounceType {
        case lxmf
        case node
        case transport
        case unknown
    }
}
