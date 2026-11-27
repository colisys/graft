import Foundation

/// The display/transport implementation used by a runtime environment.
///
/// Graft currently ships with XQuartz. The Wayland entry is a deliberate
/// placeholder so the rest of the app can be written against a capability
/// model instead of XQuartz-specific assumptions.
public enum DisplayBackendKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case xquartz
    case wayland

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .xquartz: return "XQuartz"
        case .wayland: return "Wayland"
        }
    }
}

public enum DisplayWrapperKind: String, Sendable, Equatable {
    case xquartzScript
    case unsupported
}

public struct DisplayBackendCapabilities: Sendable, Equatable {
    public var seamlessWindows: Bool
    public var clipboard: Bool
    public var audio: Bool
    public var gpuAcceleration: Bool
    public var refreshControl: Bool
    public var requiresExternalServer: Bool
    public var implemented: Bool
    public var wrapperKind: DisplayWrapperKind
    public var note: String

    public init(
        seamlessWindows: Bool,
        clipboard: Bool,
        audio: Bool,
        gpuAcceleration: Bool,
        refreshControl: Bool,
        requiresExternalServer: Bool,
        implemented: Bool,
        wrapperKind: DisplayWrapperKind,
        note: String = ""
    ) {
        self.seamlessWindows = seamlessWindows
        self.clipboard = clipboard
        self.audio = audio
        self.gpuAcceleration = gpuAcceleration
        self.refreshControl = refreshControl
        self.requiresExternalServer = requiresExternalServer
        self.implemented = implemented
        self.wrapperKind = wrapperKind
        self.note = note
    }
}

/// Display settings resolved from the runtime and passed to a backend.
public struct DisplayBackendSettings: Sendable, Equatable {
    public var maxRefreshRate: Int
    public var shimAvailable: Bool
    public var indirectGLXEnabled: Bool

    public init(
        maxRefreshRate: Int = 0,
        shimAvailable: Bool = false,
        indirectGLXEnabled: Bool = false
    ) {
        self.maxRefreshRate = max(0, maxRefreshRate)
        self.shimAvailable = shimAvailable
        self.indirectGLXEnabled = indirectGLXEnabled
    }
}

/// A resolved display session for a container and its applications.
public struct DisplaySession: Sendable, Equatable {
    public var kind: DisplayBackendKind
    /// Value used for `DISPLAY` in `docker exec` / `docker run`.
    public var containerDisplay: String
    /// Additional container environment (for example WAYLAND_DISPLAY).
    public var containerEnvironment: [String: String]
    /// Environment prefixes required by X11 clients in this session.
    public var refreshEnvironment: [String]
    /// Effective refresh presented to clients, or 0 when no cap is available.
    public var refreshRate: Int
    public var supportsGPU: Bool

    public init(
        kind: DisplayBackendKind,
        containerDisplay: String,
        containerEnvironment: [String: String] = [:],
        refreshEnvironment: [String] = [],
        refreshRate: Int = 0,
        supportsGPU: Bool = false
    ) {
        self.kind = kind
        self.containerDisplay = containerDisplay
        self.containerEnvironment = containerEnvironment
        self.refreshEnvironment = refreshEnvironment
        self.refreshRate = max(0, refreshRate)
        self.supportsGPU = supportsGPU
    }
}

public protocol DisplayBackend: Sendable {
    var kind: DisplayBackendKind { get }
    var capabilities: DisplayBackendCapabilities { get }
    func session(for base: BaseImage, settings: DisplayBackendSettings) -> DisplaySession
}

public struct XQuartzDisplayBackend: DisplayBackend {
    public let kind: DisplayBackendKind = .xquartz

    public var capabilities: DisplayBackendCapabilities {
        DisplayBackendCapabilities(
            seamlessWindows: true,
            clipboard: true,
            audio: false,
            gpuAcceleration: false,
            refreshControl: true,
            requiresExternalServer: true,
            implemented: true,
            wrapperKind: .xquartzScript,
            note: "Rootless XQuartz with a local XRandR refresh shim."
        )
    }

    public init() {}

    public func session(
        for base: BaseImage,
        settings: DisplayBackendSettings
    ) -> DisplaySession {
        var refreshEnvironment: [String] = []
        let rate = max(0, settings.maxRefreshRate)
        if rate > 0, settings.shimAvailable {
            refreshEnvironment = [
                "LD_PRELOAD=\(XRandRShim.containerPath)",
                "GRAFT_MAX_REFRESH=\(rate)"
            ]
        }
        return DisplaySession(
            kind: .xquartz,
            containerDisplay: GraftConstants.display,
            containerEnvironment: ["DISPLAY": GraftConstants.display],
            refreshEnvironment: refreshEnvironment,
            refreshRate: refreshEnvironment.isEmpty ? 0 : rate,
            // XQuartz only offers GLX when indirect GLX is enabled, and never
            // has a hardware GPU from the Linux container's perspective.
            supportsGPU: settings.indirectGLXEnabled
        )
    }
}

/// Placeholder for the future Wayland transport. It exposes the contract and
/// capability model but deliberately does not pretend to be usable yet.
public struct WaylandDisplayBackend: DisplayBackend {
    public let kind: DisplayBackendKind = .wayland

    public var capabilities: DisplayBackendCapabilities {
        DisplayBackendCapabilities(
            seamlessWindows: true,
            clipboard: true,
            audio: true,
            gpuAcceleration: false,
            refreshControl: true,
            requiresExternalServer: true,
            implemented: false,
            wrapperKind: .unsupported,
            note: "Experimental only: requires a container compositor and a macOS Wayland client."
        )
    }

    public init() {}

    public func session(
        for base: BaseImage,
        settings: DisplayBackendSettings
    ) -> DisplaySession {
        DisplaySession(
            kind: .wayland,
            containerDisplay: ":0",
            containerEnvironment: [
                "DISPLAY": ":0",
                "WAYLAND_DISPLAY": "wayland-0",
                "XDG_RUNTIME_DIR": "/tmp/runtime-graft"
            ],
            refreshEnvironment: [],
            refreshRate: max(0, settings.maxRefreshRate),
            supportsGPU: false
        )
    }
}

public enum DisplayBackends {
    public static let all: [any DisplayBackend] = [
        XQuartzDisplayBackend(),
        WaylandDisplayBackend()
    ]

    public static func backend(for kind: DisplayBackendKind) -> any DisplayBackend {
        switch kind {
        case .xquartz: return XQuartzDisplayBackend()
        case .wayland: return WaylandDisplayBackend()
        }
    }
}
