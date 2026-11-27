//
// GraftLauncher — native launcher embedded in generated .app bundles.
// Copyright (C) 2026 The Graft Authors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Generated wrappers use this small AppKit process as CFBundleExecutable.
// It finishes NSApplication launch (so the Dock stops bouncing) and then
// runs the shell script in Contents/Resources/launch.sh.
//
import AppKit
import Foundation

final class LauncherDelegate: NSObject, NSApplicationDelegate {
    private var child: Process?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let scriptURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("launch.sh")

        guard FileManager.default.isReadableFile(atPath: scriptURL.path) else {
            NSApp.terminate(nil)
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        var environment = ProcessInfo.processInfo.environment
        if let screen = NSScreen.main, screen.maximumFramesPerSecond > 0 {
            environment["GRAFT_MAX_REFRESH"] = String(screen.maximumFramesPerSecond)
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }

        do {
            try process.run()
            child = process
        } catch {
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let child, child.isRunning {
            child.terminate()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

let application = NSApplication.shared
let delegate = LauncherDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.finishLaunching()
application.run()
