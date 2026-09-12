//
//  RenPyBoxGameLauncher.swift
//  RenPy Box
//
//  Bridge between the SDL/UIKit app lifecycle (PlayerMain.m) and the
//  SwiftUI library. Exposed to ObjC via the generated -Swift.h header.
//

import Foundation
import UIKit
import SwiftUI

@_silgen_name("launcher_main")
private func launcher_main(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>!) -> Int32

/// Entry point for the whole player. Called by `player_main` (in PlayerMain.m)
    /// on SDL's background startup thread after the SDL/UIKit app has launched.
@objcMembers
public final class RenPyBoxGameLauncher: NSObject {

    static let store = GameLibraryStore()

    private static var gameRunning = false
    private static var hosting: UIViewController?

    /// Called when the app finishes launching. Shows the library.
    @objc public static func startApp() {
        DispatchQueue.main.async {
            libraryLog("APP START -> presenting library")
            presentLibrary()
        }
    }

    /// Presents the SwiftUI root inside SDL's UIKit window.
    @objc public static func presentLibrary() {
        guard !gameRunning else { return }

        store.ensureTestGameSeeded()

        let root = RenPyBoxRootView().environmentObject(store)
        let controller = UIHostingController(rootView: root)
        controller.modalPresentationStyle = .fullScreen
        controller.isModalInPresentation = true
        hosting = controller
        tryPresent(attempts: 0)
    }

    private static func tryPresent(attempts: Int) {
        guard let base = keyWindow()?.rootViewController else {
            libraryLog("no root view controller yet (attempt \(attempts)); retrying")
            if attempts < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { tryPresent(attempts: attempts + 1) }
            } else if let window = keyWindow() {
                libraryLog("modal failed; attaching library as window root")
                hosting?.view.frame = window.bounds
                window.rootViewController = hosting
            } else {
                libraryLog("GAVE UP: no UIWindow available")
            }
            return
        }
        if let h = hosting, h.view.window != nil {
            libraryLog("library already on screen")
            return
        }
        guard let h = hosting else {
            libraryLog("hosting lost")
            return
        }
        libraryLog("presenting library over root \(type(of: base))")
        base.present(h, animated: false) {
            libraryLog("library presented: onScreen=\(h.view.window != nil)")
            if h.view.window == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { tryPresent(attempts: attempts + 1) }
            }
        }
    }

    /// Launches a game (blocking). `gameDir` is the path to a Ren'Py project
    /// base directory (the folder containing `game/`).
    @objc public static func launchGame(gameDir: String) -> Int32 {
        guard !gameRunning else { return -1 }
        gameRunning = true
        libraryLog("launching game at \(gameDir)")

        // Tear down the SwiftUI library sheet before Ren'Py takes the screen.
        if let hosting = hosting {
            hosting.dismiss(animated: false)
            self.hosting = nil
        }

        setenv("RENPYBOX_GAME_DIR", gameDir, 1)

        var argv: [UnsafeMutablePointer<CChar>?] = [
            strdup("RenPyBox"),
            strdup(gameDir),
            nil,
        ]
        defer {
            for p in argv { free(p) }
        }

        let result = argv.withUnsafeMutableBufferPointer { buf -> Int32 in
            launcher_main(Int32(2), buf.baseAddress)
        }

        gameRunning = false
        libraryLog("launcher_main returned \(result)")
        DispatchQueue.main.async {
            presentLibrary()
        }
        return result
    }

    private static func keyWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows }
            .flatMap { $0 }
        return windows.first(where: { $0.isKeyWindow }) ?? windows.first
    }

    static func libraryLog(_ s: String) {
        NSLog("[RenPyBox] %@", s)
        let url = GamePaths.documentsDirectory.appendingPathComponent("renpybox.log", isDirectory: false)
        let line = "[\(Date())] \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            do {
                h.seekToEndOfFile()
                try h.write(contentsOf: line.data(using: .utf8) ?? Data())
                try? h.close()
            } catch {}
        } else {
            try? line.data(using: .utf8)?.write(to: url)
        }
    }
}