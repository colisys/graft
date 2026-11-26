import Foundation

/// Which package manager Graft uses to install its external dependencies.
///
/// This is a user preference because older Macs often have trouble with
/// Homebrew bottles (forcing source builds), while MacPorts may be the
/// preferred / already-installed manager.
public enum PackageManagerKind: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case homebrew
    case macports

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic: return "自动"
        case .homebrew: return "Homebrew"
        case .macports: return "MacPorts"
        }
    }

    public var detail: String {
        switch self {
        case .automatic:
            return "优先使用已安装的 MacPorts，否则回退到 Homebrew。"
        case .homebrew:
            return "使用 brew 安装 Colima、Docker CLI 等依赖。"
        case .macports:
            return "使用 port 安装依赖，安装时会请求 macOS 管理员授权。"
        }
    }

    public var executableName: String? {
        switch self {
        case .automatic: return nil
        case .homebrew: return "brew"
        case .macports: return "port"
        }
    }

    public var website: URL? {
        switch self {
        case .automatic: return nil
        case .homebrew: return URL(string: "https://brew.sh")
        case .macports: return URL(string: "https://www.macports.org/install.php")
        }
    }
}

/// A concrete installation action derived from a dependency + package manager.
public enum InstallPlan: Equatable, Sendable {
    /// Run an executable directly (Homebrew does not need root).
    case command(executable: String, arguments: [String])
    /// Run a shell command through `osascript` with administrator privileges.
    case privilegedShell(command: String)
    /// Open a download / install guide in the browser.
    case openURL(url: String, reason: String)
    /// The selected package manager is unavailable or cannot provide this.
    case unavailable(reason: String)

    public var requiresAdministrator: Bool {
        if case .privilegedShell = self { return true }
        return false
    }
}

public enum PackageManagerInstaller {
    /// Resolves `.automatic` against the tools found on this machine.
    public static func resolve(
        preference: PackageManagerKind,
        tools: ToolLocations
    ) -> PackageManagerKind? {
        switch preference {
        case .homebrew:
            return tools.brew != nil ? .homebrew : nil
        case .macports:
            return tools.port != nil ? .macports : nil
        case .automatic:
            if tools.port != nil { return .macports }
            if tools.brew != nil { return .homebrew }
            return nil
        }
    }

    /// Builds the install plan for an external dependency.
    public static func plan(
        for dependency: DependencyKind,
        manager: PackageManagerKind,
        tools: ToolLocations
    ) -> InstallPlan {
        let resolvedManager: PackageManagerKind
        if manager == .automatic {
            guard let resolved = resolve(preference: .automatic, tools: tools) else {
                return .unavailable(
                    reason: "未检测到 Homebrew 或 MacPorts。请先安装其中一个包管理器，或在设置中手动选择。"
                )
            }
            resolvedManager = resolved
        } else {
            resolvedManager = manager
        }

        switch resolvedManager {
        case .homebrew:
            guard let brew = tools.brew else {
                return .unavailable(reason: "未找到 Homebrew。请从 https://brew.sh 安装。")
            }
            switch dependency {
            case .homebrew:
                return .openURL(url: "https://brew.sh", reason: "当前选择 Homebrew。")
            case .macports:
                return .openURL(
                    url: "https://www.macports.org/install.php",
                    reason: "当前选择 Homebrew；如需切换请在上方包管理器选项中选择 MacPorts。"
                )
            case .colima:
                return .command(executable: brew, arguments: ["install", "colima"])
            case .docker:
                return .command(executable: brew, arguments: ["install", "docker"])
            case .librsvg:
                return .command(executable: brew, arguments: ["install", "librsvg"])
            case .xquartz:
                return .openURL(
                    url: "https://github.com/XQuartz/XQuartz/releases",
                    reason: "XQuartz 由 Graft 直接从 GitHub Releases 下载并安装。"
                )
            }

        case .macports:
            guard let port = tools.port else {
                return .unavailable(
                    reason: "未找到 MacPorts 的 port 命令。请从 https://www.macports.org/install.php 安装。"
                )
            }
            switch dependency {
            case .homebrew:
                return .openURL(url: "https://brew.sh", reason: "当前选择 MacPorts。")
            case .macports:
                return .openURL(
                    url: "https://www.macports.org/install.php",
                    reason: "当前选择 MacPorts；如需切换请在上方包管理器选项中选择 Homebrew。"
                )
            case .colima:
                return .privilegedShell(command: portCommand(port, ["install", "colima"]))
            case .docker:
                return .privilegedShell(command: portCommand(port, ["install", "docker"]))
            case .librsvg:
                return .privilegedShell(command: portCommand(port, ["install", "librsvg"]))
            case .xquartz:
                return .openURL(
                    url: "https://github.com/XQuartz/XQuartz/releases",
                    reason: "XQuartz 由 Graft 直接从 GitHub Releases 下载并安装。"
                )
            }

        case .automatic:
            return .unavailable(reason: "无法解析包管理器。")
        }
    }

    /// MacPorts requires root. Include the MacPorts bin/sbin directories in
    /// PATH so `port` can find its own helper tools under `osascript`.
    private static func portCommand(_ port: String, _ arguments: [String]) -> String {
        let binDirectory = (port as NSString).deletingLastPathComponent
        let prefix = (binDirectory as NSString).deletingLastPathComponent
        let pathValue = "\(binDirectory):\(prefix)/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
        return "export PATH=\(ShellQuote.quote(pathValue)); " + ShellQuote.command(port, arguments)
    }
}
