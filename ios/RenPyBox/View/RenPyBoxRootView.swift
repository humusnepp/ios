//
//  RenPyBoxRootView.swift
//  RenPy Box
//

import SwiftUI

struct RenPyBoxRootView: View {
    @EnvironmentObject var store: GameLibraryStore

    var body: some View {
        NavigationStack {
            LibraryView()
        }
        .preferredColorScheme(.dark)
    }
}