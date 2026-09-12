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

/// Entry point for yhe whole player. Called by `player_main` (in PlayerMain.m)
/// on the main thread after the SDL/UIKit app has launched.
@objcMembers
public final class RenPyBoxGameLauncher: NSObject {

    static let store = GameLibraryStore()

    private static var gameRunning = false
    private static var hosting: UIViewController?

    /// Called when the app finishes launching. Shows the library.
    @objc public static func startApp() {
        DispatchQueue.main.async {
            presentLibrary()
        }
    }

    /// Presents the SwiftUI root inside SDL's UIKit window.
    @objc public static func presentLibrary() {
        guard !gameRunning else { return }

        let root = RenPyBoxRootView().environmentObject(store)
        let controller = UIHostingController(rootView: root)
        controller.modalPresentationStyle = .fullScreen
        controller.isModalInPresentation = true
        hosting = controller

        guard let base = keyWindow()?.rootViewController else { return }
        base.present(controller, animated: false)
    }

    /// Launches a game (blocking). `gameDir` is the path to a Ren'Py project
    /// base directory (the folder containing `game/`).
    @objc public static func launchGame(gameDir: String) -> Int32 {
        guard !gameRunning else { return -1 }
        gameRunning = true

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
}