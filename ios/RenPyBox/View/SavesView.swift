//
//  SavesView.swift
//  RenPy Box
//

import SwiftUI
import UniformTypeIdentifiers

struct SavesView: View {
    @EnvironmentObject var store: GameLibraryStore
    let game: RenPyGame

    var body: some View {
        let saves = store.saves(for: game)

        Group {
            if saves.isEmpty {
                ContentUnavailableView("No saves",
                                       systemImage: "archivebox",
                                       description: Text("Saves made inside the game will appear here."))
            } else {
                List {
                    ForEach(saves, id: \.self) { url in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.lastPathComponent)
                                    .lineLimit(1)
                                if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) {
                                    Text(date, style: .date)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            ShareLink(item: url) {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                store.deleteSave(at: url)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Saves · \(game.name)")
    }
}