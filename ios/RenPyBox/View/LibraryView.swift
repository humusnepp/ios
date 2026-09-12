//
//  LibraryView.swift
//  RenPy Box
//

import SwiftUI
import UIKit

struct LibraryView: View {
    @EnvironmentObject var store: GameLibraryStore

    @State private var showFileImporter = false
    @State private var showWiFi = false
    @State private var importing = false
    @State private var importError: String?
    @State private var confirmingDelete: RenPyGame?

    private let columns = [
        GridItem(.adaptive(minimum: 220), spacing: 20),
    ]

    var body: some View {
        Group {
            if store.games.isEmpty && !importing {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(store.games) { game in
                            gameCard(game)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("RenPy Box")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
                    Button {
                        showWiFi = true
                    } label: {
                        Image(systemName: "wifi")
                    }
                    Button {
                        showFileImporter = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showWiFi) {
            WiFiTransferView()
                .environmentObject(store)
        }
        .sheet(isPresented: $showFileImporter) {
            FilePickerView { urls in
                importFiles(urls)
            }
        }
        .overlay {
            if importing {
                ProgressView("Importing…")
                    .padding(24)
                    .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .alert("Import failed", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .confirmationDialog("Delete this game?", isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let game = confirmingDelete { store.remove(game) }
            }
        }
        .onAppear { store.refresh() }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("No games yet")
                .font(.title2.bold())
            Text("Upload Ren'Py game archives (ZIP/TAR/GZ) from your phone via the Files app, or from a computer on the same Wi-Fi.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 40)
            HStack(spacing: 16) {
                Button {
                    showFileImporter = true
                } label: {
                    Label("Files", systemImage: "folder")
                        .padding(.horizontal, 12).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    showWiFi = true
                } label: {
                    Label("Wi-Fi", systemImage: "wifi")
                        .padding(.horizontal, 12).padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: Game card

    private func gameCard(_ game: RenPyGame) -> some View {
        Button {
            launch(game)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                cover(for: game)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(Color.black.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                Text(game.name)
                    .font(.headline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("\(store.saves(for: game).count) saves")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                launch(game)
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            NavigationLink {
                SavesView(game: game)
                    .environmentObject(store)
            } label: {
                Label("Saves", systemImage: "archivebox")
            }
            NavigationLink {
                TranslationsView(game: game)
                    .environmentObject(store)
            } label: {
                Label("Translations", systemImage: "globe")
            }
            Button(role: .destructive) {
                confirmingDelete = game
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func cover(for game: RenPyGame) -> some View {
        if let img = store.cover(for: game) {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Rectangle().fill(.quinary)
                Image(systemName: "square.stack.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Actions

    private func launch(_ game: RenPyGame) {
        _ = RenPyBoxGameLauncher.launchGame(gameDir: game.directory.path)
        store.refresh()
    }

    private func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        importing = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                for url in urls {
                    _ = try store.install(archiveURL: url)
                }
                DispatchQueue.main.async {
                    importing = false
                }
            } catch {
                DispatchQueue.main.async {
                    importing = false
                    importError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                }
            }
        }
    }
}