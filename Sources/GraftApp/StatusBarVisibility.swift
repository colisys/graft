import Foundation
import AppKit
import CoreGraphics

/// Detects whether the app's status item is actually on a visible screen.
///
/// macOS (and menu bar managers such as Hidden Bar / Bartender) move status
/// items to negative X coordinates when the menu bar is full. The app is still
/// running and the item exists, but the user cannot see or click it. In that
/// case Graft opens its management window instead.
enum StatusBarVisibility {
    static func hasVisibleStatusItem(processID: pid_t = getpid()) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let displays = activeDisplayBounds()

        for window in windows {
            let ownerPID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            guard ownerPID == processID else { continue }

            let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
            guard layer == 25 else { continue } // status item layer

            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let x = (bounds["X"] as? NSNumber)?.doubleValue,
                  let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue,
                  width > 0, height > 0 else {
                continue
            }

            let rect = CGRect(x: x, y: y, width: width, height: height)
            guard height >= 18, height <= 40 else { continue }
            if displays.contains(where: { $0.intersects(rect) }) {
                return true
            }
        }
        return false
    }

    private static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return NSScreen.screens.map(\.frame)
        }
        var identifiers = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &identifiers, &count) == .success else {
            return NSScreen.screens.map(\.frame)
        }
        return identifiers.map { CGDisplayBounds($0) }
    }
}
