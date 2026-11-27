import Foundation

/// Launch behavior shared by a family of Linux applications.
///
/// The resolver is intentionally data-driven: adding a new Chromium-family
/// executable should not require another branch in the container launcher.
public enum ApplicationProfileKind: String, CaseIterable, Identifiable, Sendable {
    case electron
    case chromium
    case firefox
    case generic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .electron: return "Electron"
        case .chromium: return "Chromium"
        case .firefox: return "Firefox"
        case .generic: return "Generic X11"
        }
    }
}

public struct ApplicationProfile: Sendable, Equatable {
    public var kind: ApplicationProfileKind
    /// Electron and Chromium share the Ozone/X11 launch flags.
    public var isChromiumFamily: Bool
    public var requiresNoSandbox: Bool
    public var supportsGPUFlags: Bool
    public var usesChromiumScale: Bool
    public var supportsFrameRateUnlock: Bool
    /// Environment entries required by this application, in `KEY=value` form.
    public var environment: [String]

    public init(
        kind: ApplicationProfileKind,
        isChromiumFamily: Bool,
        requiresNoSandbox: Bool,
        supportsGPUFlags: Bool,
        usesChromiumScale: Bool,
        supportsFrameRateUnlock: Bool,
        environment: [String] = []
    ) {
        self.kind = kind
        self.isChromiumFamily = isChromiumFamily
        self.requiresNoSandbox = requiresNoSandbox
        self.supportsGPUFlags = supportsGPUFlags
        self.usesChromiumScale = usesChromiumScale
        self.supportsFrameRateUnlock = supportsFrameRateUnlock
        self.environment = environment
    }
}

public enum ApplicationProfileResolver {
    public static let electronExecutables: Set<String> = [
        "code", "code-insiders", "codium", "electron",
        "slack", "discord", "obsidian", "notion",
        "postman", "element-desktop", "signal-desktop", "figma-linux"
    ]

    public static let chromiumExecutables: Set<String> = [
        "chromium", "chromium-browser", "google-chrome",
        "google-chrome-stable", "brave-browser"
    ]

    public static func profile(for entry: DesktopEntry) -> ApplicationProfile {
        let executable = entry.executableToken.lowercased()

        if isFirefox(entry: entry, executable: executable) {
            return ApplicationProfile(
                kind: .firefox,
                isChromiumFamily: false,
                requiresNoSandbox: false,
                supportsGPUFlags: false,
                usesChromiumScale: false,
                supportsFrameRateUnlock: false,
                environment: ["MOZ_DISABLE_CONTENT_SANDBOX=1"]
            )
        }

        if electronExecutables.contains(executable) || isElectronDesktopEntry(entry) {
            return electronProfile()
        }

        if chromiumExecutables.contains(executable) {
            return ApplicationProfile(
                kind: .chromium,
                isChromiumFamily: true,
                requiresNoSandbox: true,
                supportsGPUFlags: true,
                usesChromiumScale: true,
                supportsFrameRateUnlock: true
            )
        }

        return ApplicationProfile(
            kind: .generic,
            isChromiumFamily: false,
            requiresNoSandbox: false,
            supportsGPUFlags: false,
            usesChromiumScale: false,
            supportsFrameRateUnlock: false
        )
    }

    private static func electronProfile() -> ApplicationProfile {
        ApplicationProfile(
            kind: .electron,
            isChromiumFamily: true,
            requiresNoSandbox: true,
            supportsGPUFlags: true,
            usesChromiumScale: true,
            supportsFrameRateUnlock: true
        )
    }

    private static func isElectronDesktopEntry(_ entry: DesktopEntry) -> Bool {
        if entry.categories.contains(where: {
            $0.caseInsensitiveCompare("Electron") == .orderedSame
        }) {
            return true
        }
        return entry.startupWMClass?.lowercased().contains("electron") == true
    }

    private static func isFirefox(entry: DesktopEntry, executable: String) -> Bool {
        executable == "firefox" || entry.name.lowercased().contains("firefox")
    }
}
