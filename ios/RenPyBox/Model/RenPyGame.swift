//
//  RenPyGame.swift
//  RenPy Box
//

import Foundation

/// A Ren'Py game installed under Documents/stories/<name>.
struct RenPyGame: Identifiable, Hashable {
    let id: String          // directory name, unique
    let name: String        // display name

    var directory: URL {    // base dir containing game/
        GamePaths.storiesDirectory.appendingPathComponent(id, isDirectory: true)
    }
    var gameDirectory: URL {
        directory.appendingPathComponent("game", isDirectory: true)
    }
    var savesDirectory: URL {
        gameDirectory.appendingPathComponent("saves", isDirectory: true)
    }

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    /// True when the project has a loadable script (rpy or compiled rpyc).
    var isPlayable: Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("game/script.rpy").path)
            || FileManager.default.fileExists(atPath: directory.appendingPathComponent("game/script.rpyc").path)
    }
}

/// Centralised paths for the whole app.
enum GamePaths {
    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    static var storiesDirectory: URL {
        documentsDirectory.appendingPathComponent("stories", isDirectory: true)
    }
    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RenPyBox", isDirectory: true)
    }
    static var coversDirectory: URL {
        supportDirectory.appendingPathComponent("covers", isDirectory: true)
    }
    static var inboxDirectory: URL {
        documentsDirectory.appendingPathComponent("inbox", isDirectory: true)
    }
}