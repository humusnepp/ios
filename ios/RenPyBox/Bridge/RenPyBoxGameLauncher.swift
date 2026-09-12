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
    private static var sdlRoot: UIViewController?

    /// Called when the app finishes launching. Shows the library.
    @objc public static func startApp() {
        DispatchQueue.main.async {
            RenPyBoxBoot.showBootInfo()
            RenPyBoxBoot.mark("boot: startApp on main queue")
            presentLibrary()
        }
    }

    /// Presents the SwiftUI library by swapping it in as the window's root
    /// view controller (SDL's original root is stashed and restored when a
    /// game launches). This can't silently fail like a modal presentation.
    @objc public static func presentLibrary() {
        guard !gameRunning else {
            RenPyBoxBoot.mark("presentLibrary skipped: game running")
            return
        }

        store.ensureTestGameSeeded()
        RenPyBoxBoot.mark("presentLibrary: library games=\(store.games.count)")

        let controller = hosting ?? {
            let c = UIHostingController(rootView: RenPyBoxRootView().environmentObject(store))
            hosting = c
            return c
        }()

        guard let window = keyWindow() else {
            RenPyBoxBoot.mark("presentLibrary: NO WINDOW - retrying in 0.5s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { presentLibrary() }
            return
        }

        if window.rootViewController !== controller {
            sdlRoot = window.rootViewController
            controller.view.frame = window.bounds
            window.rootViewController = controller
            RenPyBoxBoot.mark("library attached as window root (prev=\(sdlRoot.map { String(describing: type(of: $0)) } ?? "nil"))")
        } else {
            RenPyBoxBoot.mark("library already attached")
        }
    }

    /// Launches a game (blocking). `gameDir` is the path to a Ren'Py project
    /// base directory (the folder containing `game/`).
    @objc public static func launchGame(gameDir: String) -> Int32 {
        guard !gameRunning else { return -1 }
        gameRunning = true
        RenPyBoxBoot.mark("launch game: \(gameDir)")

        // Put SDL's view controller back so Ren'Py renders into its window.
        if let window = keyWindow(), let sdl = sdlRoot {
            window.rootViewController = sdl
            RenPyBoxBoot.mark("library detached, SDL root restored")
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
        RenPyBoxBoot.mark("launcher_main returned \(result)")
        DispatchQueue.main.async {
            presentLibrary()
        }
        return result
    }

    /// Covered by RenPyBoxBoot.mark.
    static func libraryLog(_ s: String) {
        RenPyBoxBoot.mark(s)
    }

    private static func keyWindow() -> UIWindow? {
        if let w = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) ?? UIApplication.shared.windows.first {
            return w
        }
        return UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows }
            .flatMap { $0 }
            .first
    }
}