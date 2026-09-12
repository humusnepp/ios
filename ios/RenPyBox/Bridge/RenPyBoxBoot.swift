//
//  RenPyBoxBoot.swift
//  RenPy Box
//
//  Boot-time diagnostics: every milestone is shown as a yellow overlay on the
//  screen (so a black screen can never hide what happened), mirrored to stderr
//  and appended to renpybox.log in Documents.
//

import Foundation
import UIKit
import Darwin

@objcMembers
public final class RenPyBoxBoot: NSObject {

    private static let logURL = GamePaths.documentsDirectory
        .appendingPathComponent("renpybox.log", isDirectory: false)

    private static var label: UILabel?
    private static var lines: [String] = []

    /// Records a milestone: NSLog + stderr + file + on-screen overlay.
    @objc public static func mark(_ s: String) {
        NSLog("[RenPyBox] %@", s)
        fputs("[RenPyBox] \(s)\n", stderr)

        lines.append(s)
        if lines.count > 12 {
            lines.removeFirst(lines.count - 12)
        }
        let text = lines.joined(separator: "\n")

        let line = "[\(Date())] \(s)\n"
        if let h = try? FileHandle(forWritingTo: logURL) {
            do {
                h.seekToEndOfFile()
                try h.write(contentsOf: line.data(using: .utf8) ?? Data())
                try? h.close()
            } catch {}
        } else {
            try? line.data(using: .utf8)?.write(to: logURL)
        }

        DispatchQueue.main.async {
            show(text)
        }
    }

    @objc public static func showBootInfo() {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let bundleId = Bundle.main.bundleIdentifier ?? "?"
        mark("RenPyBox v\(version) (\(build)) id=\(bundleId)")
    }

    private static func show(_ text: String) {
        guard let window = UIApplication.shared.windows.first else { return }
        let existing = label ?? {
            let l = UILabel(frame: CGRect(x: 0, y: 0, width: 360, height: 320))
            l.numberOfLines = 0
            l.textColor = .yellow
            l.backgroundColor = UIColor.black.withAlphaComponent(0.55)
            l.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            l.textAlignment = .left
            l.layer.zPosition = 1000
            window.addSubview(l)
            window.bringSubviewToFront(l)
            label = l
            return l
        }()
        existing.center = CGPoint(x: window.bounds.midX, y: 0)
        existing.frame.origin.y = 30
        existing.frame.size.width = min(window.bounds.width - 20, 540)
        existing.text = text
        window.bringSubviewToFront(existing)

        // Hide after a while so it doesn't permanently cover the library.
        let snapshot = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
            if existing.text == snapshot {
                existing.isHidden = true
            }
        }
    }
}