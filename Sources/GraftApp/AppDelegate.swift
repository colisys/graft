import Foundation
import AppKit
import Darwin
import GraftCore

/// Application delegate responsible for:
/// 1. guaranteeing a single Graft instance, and
/// 2. re-opening the management window when the user launches Graft again
///    while it is already running (common when the menu bar icon is hidden).
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let reopenNotification = Notification.Name("app.graft.reopen")

    private var lockDescriptor: Int32 = -1
    private var reopenObserver: NSObjectProtocol?

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard acquireSingleInstanceLock() else {
            // Another instance is already running. Ask it to show its window,
            // then exit this duplicate.
            DistributedNotificationCenter.default().postNotificationName(
                Self.reopenNotification,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            NSApp.terminate(nil)
            return
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        reopenObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.reopenNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AppModel.shared.showManagementWindow()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in
            AppModel.shared.showManagementWindow()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let reopenObserver {
            DistributedNotificationCenter.default().removeObserver(reopenObserver)
        }
        if lockDescriptor >= 0 {
            Darwin.close(lockDescriptor)
            lockDescriptor = -1
        }
    }

    /// A file lock is released automatically by the kernel when the process
    /// exits, so a crashed instance cannot leave a stale lock behind.
    private func acquireSingleInstanceLock() -> Bool {
        SessionRegistry.prepare()
        let path = SessionRegistry.supportDirectory.appendingPathComponent("graft.lock").path
        let descriptor = Darwin.open(path, O_CREAT | O_RDWR, mode_t(0o644))
        guard descriptor >= 0 else { return true }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            Darwin.close(descriptor)
            return false
        }
        lockDescriptor = descriptor
        return true
    }
}
