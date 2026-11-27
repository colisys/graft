import AppKit
import CoreGraphics
import Foundation

/// The refresh rate of the main macOS display.
///
/// `CGDisplayModeGetRefreshRate` returns 0 for many built-in displays, so
/// `NSScreen.maximumFramesPerSecond` is the primary source and 60 Hz is the
/// final fallback.
public enum DisplayRefreshRate {
    public static func current() -> Int {
        if let screen = NSScreen.main, screen.maximumFramesPerSecond > 0 {
            return Int(screen.maximumFramesPerSecond)
        }
        if let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()) {
            let rate = mode.refreshRate
            if rate > 0 {
                return Int(rate.rounded())
            }
        }
        return 60
    }
}
