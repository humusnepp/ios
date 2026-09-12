//
//  TranslationsView.swift
//  RenPy Box
//
//  Lists the languages bundled in the game's tl/ folder; choosing one sets
//  Ren'Py's config.language for that game (persisted to .renpybox.lang).
//

import SwiftUI

struct TranslationsView: View {
    @EnvironmentObject var store: GameLibraryStore
    let game: RenPyGame

    @State private var selection: String?

    var body: some View {
        let languages = store.languages(for: game)

        Group {
            if languages.isEmpty {
                ContentUnavailableView("No translations",
                                       systemImage: "globe",
                                       description: Text("This game does not ship any translation packs."))
            } else {
                List {
                    Section {
                        ForEach(languages, id: \.self) { lang in
                            Button {
                                selection = (selection == lang) ? nil : lang
                                store.setLanguage(selection, for: game)
                            } label: {
                                HStack {
                                    Text(Locale(identifier: lang).localizedString(forIdentifier: lang) ?? lang)
                                    Spacer()
                                    if selection == lang {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                        }
                    } footer: {
                        Text("Language is used the next time the game starts.")
                    }

                    if selection != nil {
                        Section {
                            Button("Use the game's default language") {
                                selection = nil
                                store.setLanguage(nil, for: game)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Translations · \(game.name)")
        .onAppear {
            selection = store.language(for: game)
        }
    }
}