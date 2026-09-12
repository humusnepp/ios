//
//  GameImporter.swift
//  RenPy Box
//
//  Turns an uploaded archive (ZIP/TAR/GZ) into an installed game under
//  Documents/stories/<Name>.
//

import Foundation
import UIKit

enum ImportError: LocalizedError {
    case notARenPyGame(String)

    var errorDescription: String? {
        switch self {
        case .notARenPyGame(let m): return "Not a Ren'Py game: \(m)"
        }
    }
}

struct GameImporter {

    /// Extracts `src` (archive or folder) and installs the Ren'Py project it
    /// contains into the library. Returns the installed game.
    static func importSource(at src: URL, progress: @escaping (Double) -> Void) throws -> RenPyGame {
        let fm = FileManager.default
        try fm.createDirectory(at: GamePaths.storiesDirectory, withIntermediateDirectories: true)

        let work = fm.temporaryDirectory.appendingPathComponent("rpb-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        var isDir: ObjCBool = false
        if fm.fileExists(atPath: src.path, isDirectory: &isDir), isDir.boolValue {
            // Folder import (from Files app): copy as-is.
            let dest = work.appendingPathComponent("root")
            try fm.copyItem(at: src, to: dest)
        } else {
            try Archive.extractArchive(at: src, to: work, progress: progress)
        }

        // Find the project root: the directory that contains `game/`.
        guard let root = findProjectRoot(in: work) else {
            throw ImportError.notARenPyGame("No `game/` folder was found in the archive.")
        }

        let displayName = gameName(from: root) ?? defaultName(src)
        let folderName = sanitize(displayName)
        let final = GamePaths.storiesDirectory.appendingPathComponent(folderName, isDirectory: true)

        if fm.fileExists(atPath: final.path) {
            try fm.removeItem(at: final)   // replace old copy
        }
        try fm.moveItem(at: root, to: final)

        // A sibling top-level folder (e.g. the itch.io wrapper) can carry extra
        // files like readme/trailers that we drop - which root already excludes.
        var game = RenPyGame(id: folderName, name: displayName)
        if !game.isPlayable {
            throw ImportError.notARenPyGame("The project has no script.rpy / .rpyc.")
        }

        generateCover(for: &game)
        return game
    }

    // MARK: Project detection

    private static func findProjectRoot(in dir: URL) -> URL? {
        let fm = FileManager.default

        if isProject(dir) { return dir }

        // Walk one level deep (archive often wraps the project in a folder).
        if let subs = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for sub in subs where sub.hasDirectoryPath {
                if isProject(sub) { return sub }
            }
        }

        // Sometimes it's nested two levels (e.g. ZipThatEndsInGame folder/game).
        if let subs1 = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for s1 in subs1 where s1.hasDirectoryPath {
                if let subs2 = try? fm.contentsOfDirectory(at: s1, includingPropertiesForKeys: nil) {
                    for s2 in subs2 where s2.hasDirectoryPath {
                        if isProject(s2) { return s2 }
                    }
                }
            }
        }
        return nil
    }

    static func isProject(_ url: URL) -> Bool {
        let fm = FileManager.default
        let gameDir = url.appendingPathComponent("game", isDirectory: true)
        guard fm.fileExists(atPath: gameDir.path) else { return false }
        let hasScript = fm.fileExists(atPath: gameDir.appendingPathComponent("script.rpy").path)
            || fm.fileExists(atPath: gameDir.appendingPathComponent("script.rpyc").path)
            || fm.fileExists(atPath: gameDir.appendingPathComponent("options.rpy").path)
        return hasScript
    }

    // MARK: Names

    static func gameName(from projectRoot: URL) -> String? {
        let options = projectRoot.appendingPathComponent("game/options.rpy")
        let alternatives = ["game/script.rpy", "game/gui.rpy"]
        guard let data = try? Data(contentsOf: options) else {
            for alt in alternatives {
                let u = projectRoot.appendingPathComponent(alt)
                if let d = try? Data(contentsOf: u), let s = String(data: d, encoding: .utf8) {
                    if let n = extractName(s) { return n }
                }
            }
            return nil
        }
        guard let s = String(data: data, encoding: .utf8) else { return nil }
        return extractName(s)
    }

    private static func extractName(_ text: String) -> String? {
        // Find the line(s) that define config.name, then grab the quoted value.
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(line)
            guard line.contains("config.name") || line.contains("config\.name.match") else { continue }
            guard let quoteStart = firstQuoteIndex(in: line) else { continue }
            var result = String.UnicodeScalarView()
            for sc in line.unicodeScalars.dropFirst(quoteStart.1 + 1) {
                if sc == "\"" || sc == "“" || sc == "”" || sc == "'" || sc == "’" { break }
                result.append(sc)
            }
            let name = String(result)
            if !name.isEmpty { return name }
        }
        return nil
    }

    private static func firstQuoteIndex(in line: String) -> (Character, Int)? {
        var i = 0
        for ch in line {
            if ch == "\"" || ch == "“" || ch == "'" { return (ch, i) }
            i += 1
        }
        return nil
    }

    private static func defaultName(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    private static func sanitize(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            if ch.isASCII && ch.properties.isAlphabetic || ch.properties.isNumber || ch == "-" || ch == "_" || ch == " " {
                out.append(Character(ch))
            }
        }
        out = out.trimmingCharacters(in: .whitespaces)
        return out.isEmpty ? "Game" : out.replacingOccurrences(of: " ", with: "_")
    }

    // MARK: Covers

    /// Picks artwork from the game's own assets as a cover thumbnail.
    static func pickCover(in project: URL) -> UIImage? {
        let fm = FileManager.default
        let gameDir = project.appendingPathComponent("game", isDirectory: true)
        let candidates = [
            "gui/main_menu.png",
            "gui/main_menu.jpg",
            "gui/menu_bg.png",
            "images/main_menu.png",
            "images/main_menu.jpg",
            "gui/title.png",
        ]
        for rel in candidates {
            let u = gameDir.appendingPathComponent(rel)
            if let img = UIImage(contentsOfFile: u.path) { return img }
        }
        // Fallback: first image in gui/ or images/.
        for folder in ["gui", "images"] {
            let dir = gameDir.appendingPathComponent(folder, isDirectory: true)
            if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                let images = files.filter { ["png", "jpg", "jpeg", "webp"].contains($0.pathExtension.lowercased()) }
                if let first = images.first, let img = UIImage(contentsOfFile: first.path) {
                    return img
                }
            }
        }
        return nil
    }

    private static func generateCover(for game: inout RenPyGame) {
        guard let img = pickCover(in: game.directory) else { return }
        let target = GamePaths.coversDirectory
            .appendingPathComponent("\(game.id).png")
        if let thumb = img.scaledDown(to: 600) {
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? thumb.pngData()?.write(to: target, options: .atomic)
        }
    }
}

extension UIImage {
    func scaledDown(to maxDim: CGFloat) -> UIImage? {
        let scale = min(1.0, maxDim / max(size.width, size.height))
        guard scale < 1.0 else { return self }
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}