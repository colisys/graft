import Foundation

/// How Graft presents the macOS display refresh rate to Linux/X11 clients.
public enum MaxRefreshRateMode: String, CaseIterable, Identifiable, Sendable {
    case matchDisplay
    case hz30
    case hz60
    case hz120
    case unlimited

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .matchDisplay: return "匹配 macOS"
        case .hz30: return "30 Hz"
        case .hz60: return "60 Hz"
        case .hz120: return "120 Hz"
        case .unlimited: return "不限制（旧行为）"
        }
    }

    public var isAuto: Bool { self == .matchDisplay }
    public var isUnlimited: Bool { self == .unlimited }

    /// Returns the cap in Hz, or nil for the legacy unlimited mode.
    public func resolvedHz(detected: Int) -> Int? {
        switch self {
        case .matchDisplay:
            return max(1, detected > 0 ? detected : 60)
        case .hz30:
            return 30
        case .hz60:
            return 60
        case .hz120:
            return 120
        case .unlimited:
            return nil
        }
    }
}
