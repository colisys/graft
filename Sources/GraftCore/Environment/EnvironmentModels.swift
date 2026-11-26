import Foundation

/// External tools Graft can detect, install and drive.
public enum DependencyKind: String, CaseIterable, Identifiable, Sendable {
    case homebrew
    case macports
    case colima
    case docker
    case xquartz
    case librsvg

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .homebrew: return "Homebrew"
        case .macports: return "MacPorts"
        case .colima: return "Colima"
        case .docker: return "Docker CLI"
        case .xquartz: return "XQuartz"
        case .librsvg: return "librsvg (SVG 图标)"
        }
    }

    public var detail: String {
        switch self {
        case .homebrew:
            return "macOS 包管理器，用于安装其余依赖。"
        case .macports:
            return "macOS 包管理器，旧机器可优先使用它避免 Homebrew 源码编译。"
        case .colima:
            return "轻量级 Linux 虚拟机运行时。"
        case .docker:
            return "容器命令行客户端，Colima 提供守护进程。"
        case .xquartz:
            return "X11 窗口服务，负责显示 Linux GUI。"
        case .librsvg:
            return "可选，用于把 SVG 图标转换为 macOS 图标。"
        }
    }

    public var isPackageManager: Bool {
        self == .homebrew || self == .macports
    }

    public var isRequired: Bool {
        switch self {
        case .colima, .docker, .xquartz: return true
        case .homebrew, .macports, .librsvg: return false
        }
    }

    public var website: URL? {
        switch self {
        case .homebrew: return URL(string: "https://brew.sh")
        case .macports: return URL(string: "https://www.macports.org/install.php")
        case .xquartz: return URL(string: "https://www.xquartz.org")
        case .colima: return URL(string: "https://github.com/abiosoft/colima")
        case .docker: return URL(string: "https://docs.docker.com/engine/")
        case .librsvg: return URL(string: "https://wiki.gnome.org/Projects/LibRsvg")
        }
    }

    public var installHint: String {
        switch self {
        case .homebrew:
            return "从 https://brew.sh 安装 Homebrew。"
        case .macports:
            return "从 https://www.macports.org/install.php 安装 MacPorts。"
        case .xquartz:
            return "可通过 Homebrew cask 安装，或从 https://www.xquartz.org 下载官方安装包。"
        case .colima, .docker:
            return "在设置中选择包管理器后一键安装。"
        case .librsvg:
            return "可选依赖，用于 SVG 图标转换。"
        }
    }
}

/// Resolved absolute paths of the external tools.
public struct ToolLocations: Sendable, Equatable {
    public var brew: String?
    public var port: String?
    public var colima: String?
    public var docker: String?
    public var xhost: String?
    public var xquartzApp: URL?
    public var rsvgConvert: String?
    public var curl: String?
    public var sips: String?
    public var iconutil: String?
    public var open: String?
    public var pgrep: String?
    public var lsregister: String?

    public init() {}

    public var dockerAvailable: Bool { docker != nil }
    public var colimaAvailable: Bool { colima != nil }
}

/// Thread-safe holder so the container layer can read the latest tool paths
/// discovered by `EnvironmentManager` without hopping to the main actor.
public final class Toolbox: @unchecked Sendable {
    public static let shared = Toolbox()

    private let lock = NSLock()
    private var storage = ToolLocations()

    public init() {}

    public var tools: ToolLocations {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

public enum ColimaState: String, Sendable {
    case unknown
    case notInstalled
    case stopped
    case starting
    case running

    public var displayName: String {
        switch self {
        case .unknown: return "未知"
        case .notInstalled: return "未安装"
        case .stopped: return "已停止"
        case .starting: return "启动中"
        case .running: return "运行中"
        }
    }

    public var isRunning: Bool { self == .running }
}

public enum ContainerRuntimeState: String, Sendable {
    case unavailable
    case missing
    case stopped
    case running

    public var displayName: String {
        switch self {
        case .unavailable: return "不可用"
        case .missing: return "未创建"
        case .stopped: return "已停止"
        case .running: return "运行中"
        }
    }
}

public struct RuntimeStats: Sendable, Equatable {
    public var containerMemory: String?
    public var containerCPU: String?

    public init(containerMemory: String? = nil, containerCPU: String? = nil) {
        self.containerMemory = containerMemory
        self.containerCPU = containerCPU
    }
}

/// Wraps a resolved dependency for display in the UI.
public struct DependencyStatus: Identifiable, Sendable {
    public let kind: DependencyKind
    public let path: String?

    public var id: String { kind.id }
    public var installed: Bool { path != nil }

    public init(kind: DependencyKind, path: String?) {
        self.kind = kind
        self.path = path
    }
}
