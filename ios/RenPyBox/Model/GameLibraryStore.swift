//
//  GameLibraryStore.swift
//  RenPy Box
//

import Foundation
import UIKit
import Combine

/// Application-wide model: the installed games, covers, saves handling and
/// per-game settings (language).
final class GameLibraryStore: ObservableObject {

    @Published private(set) var games: [RenPyGame] = []

    init() {
        refresh()
    }

    func refresh() {
        let fm = FileManager.default
        try? fm.createDirectory(at: GamePaths.storiesDirectory, withIntermediateDirectories: true)
        let items = (try? fm.contentsOfDirectory(at: GamePaths.storiesDirectory,
                                                  includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var found: [RenPyGame] = []
        for item in items {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard GameImporter.isProject(item) else { continue }

            var name = item.lastPathComponent.replacingOccurrences(of: "_", with: " ")
            if let gameName = GameImporter.gameName(from: item) {
                name = gameName
            }
            var game = RenPyGame(id: item.lastPathComponent, name: name)
            GameImporter.generateCoverIfNeeded(&game)
            found.append(game)
        }
        games = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func install(archiveURL: URL, progress: @escaping (Double) -> Void = { _ in }) throws -> RenPyGame {
        let game = try GameImporter.importSource(at: archiveURL, progress: progress)
        DispatchQueue.main.async { self.refresh() }
        return game
    }

    func remove(_ game: RenPyGame) {
        try? FileManager.default.removeItem(at: game.directory)
        if let cover = coverFile(for: game) {
            try? FileManager.default.removeItem(at: cover)
        }
        refresh()
    }

    // MARK: Covers

    func cover(for game: RenPyGame) -> UIImage? {
        guard let cover = coverFile(for: game),
              let img = UIImage(contentsOfFile: cover.path) else { return nil }
        return img
    }

    func coverFile(for game: RenPyGame) -> URL? {
        let target = GamePaths.coversDirectory.appendingPathComponent("\(game.id).png")
        return FileManager.default.fileExists(atPath: target.path) ? target : nil
    }

    // MARK: Saves

    func saves(for game: RenPyGame) -> [URL] {
        let fm = FileManager.default
        let dirs = [game.savesDirectory,
                    GamePaths.documentsDirectory.appendingPathComponent("\(game.id)/saves", isDirectory: true)]
        var results: [URL] = []
        var seen = Set<URL>()
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            for item in items where !item.hasDirectoryPath && !seen.contains(item) {
                if item.pathExtension.lowercased() == "save" || item.pathExtension.lowercased() == "evn" {
                    seen.insert(item)
                    results.append(item)
                }
            }
        }
        return results.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
    }

    func deleteSave(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Translations

    func languages(for game: RenPyGame) -> [String] {
        let tl = game.gameDirectory.appendingPathComponent("tl", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(at: tl, includingPropertiesForKeys: nil) else {
            return []
        }
        return items
            .filter { $0.hasDirectoryPath }
            .map { $0.lastPathComponent }
            .filter { $0 != "None" }
            .sorted()
    }

    func language(for game: RenPyGame) -> String? {
        let f = game.directory.appendingPathComponent(".renpybox.lang")
        return ((try? String(contentsOf: f, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func setLanguage(_ lang: String?, for game: RenPyGame) {
        let f = game.directory.appendingPathComponent(".renpybox.lang")
        if let lang = lang, !lang.isEmpty {
            try? lang.write(to: f, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: f)
        }
    }
}

extension GameImporter {
    /// Recompute a missing cover for an already-installed game.
    static func generateCoverIfNeeded(_ game: inout RenPyGame) {
        guard let img = pickCover(in: game.directory) else { return }
        let target = GamePaths.coversDirectory.appendingPathComponent("\(game.id).png")
        if let thumb = img.scaledDown(to: 600) {
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? thumb.pngData()?.write(to: target, options: .atomic)
        }
    }
}