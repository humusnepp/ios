//
//  RenPyBoxGameLauncher.swift
//  RenPy Box
//
//  Bridge between the native UIKit/SwiftUI shell and the renios engine.
//
//  Boot model: the app is a plain iPhone app - no SDL at launch. The SwiftUI
//  library is the window's root view controller. Launching a game calls the
//  engine's exported entry `launcher_main` (provided by librenpython.a) on a
//  background thread; Ren'Py boots in-process and renders its own window.
//

import Foundation
import UIKit
import SwiftUI

@_silgen_name("launcher_main")
private func launcher_main(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>!) -> Int32

@objcMembers
public final class RenPyBoxGameLauncher: NSObject {

    static let store = GameLibraryStore()

    private static var gameRunning = false

    /// Root view controller for the native library screen (window root).
    @objc public static func libraryRootController() -> UIViewController {
        store.ensureTestGameSeeded()
        return UIHostingController(rootView: RenPyBoxRootView().environmentObject(store))
    }

    /// Launches a game (blocks until the game exits). `gameDir` is the path
    /// to a Ren'Py project base directory (the folder containing `game/`).
    @objc public static func launchGame(gameDir: String) -> Int32 {
        guard !gameRunning else { return -1 }
        gameRunning = true
        RenPyBoxBoot.mark("launch game: \(gameDir)")

        setenv("RENPYBOX_GAME_DIR", gameDir, 1)

        Thread.detachNewThread {
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
                Self.renderLibraryAgain()
            }
        }
        return 0
    }

    /// Brings the native library back after a game exits.
    private static func renderLibraryAgain() {
        guard let window = UIApplication.shared.windows.first else { return }
        window.rootViewController = libraryRootController()
        RenPyBoxBoot.mark("library restored as window root")
    }

    /// Covered by RenPyBoxBoot.mark.
    static func libraryLog(_ s: String) {
        RenPyBoxBoot.mark(s)
    }
}