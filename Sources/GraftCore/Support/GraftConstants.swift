import Foundation

/// Shared, immutable project-wide identifiers.
public enum GraftConstants {
    /// Ubuntu defaults kept for compatibility with existing installations and
    /// generated wrappers. New code should use `BaseImage` directly.
    public static let containerName = BaseImage.ubuntu.containerName
    public static let imageName = BaseImage.ubuntu.imageName
    public static let homeVolumeName = BaseImage.ubuntu.homeVolumeName
    public static let appFolderName = "AquaLinux Apps"
    public static let display = "host.docker.internal:0"
    public static let appBundleIdentifierPrefix = "app.graft.linux."
    public static let runtimeUser = "graft"
    public static let menuBarBundleIdentifier = "app.graft.menubar"
}

/// Errors surfaced to the UI with a human readable Chinese description.
public enum GraftError: Error, LocalizedError, Sendable {
    case missingDependency(DependencyKind)
    case commandFailed(String)
    case xquartzTimeout
    case colimaStartTimeout
    case invalidDesktopEntry(String)
    case containerUnavailable
    case iconExtractionFailed(String)
    case wrapperGenerationFailed(String)
    case installFailed(String)
    case dockerUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .missingDependency(let dependency):
            return "缺少依赖：\(dependency.displayName)。\(dependency.installHint)"
        case .commandFailed(let message):
            return message
        case .xquartzTimeout:
            return "XQuartz 未在预期时间内就绪。请确认 XQuartz 已启动，并且允许 TCP 连接。"
        case .colimaStartTimeout:
            return "Colima 启动超时。请检查虚拟机日志或降低分配的 CPU / 内存。"
        case .invalidDesktopEntry(let message):
            return "无法解析 .desktop 文件：\(message)"
        case .containerUnavailable:
            return "Linux 运行容器不可用，请先启动运行环境。"
        case .iconExtractionFailed(let message):
            return "无法提取应用图标：\(message)"
        case .wrapperGenerationFailed(let message):
            return "无法生成 macOS .app：\(message)"
        case .installFailed(let message):
            return "安装失败：\(message)"
        case .dockerUnavailable(let message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return """
            Docker 守护进程不可用，Colima 可能已停止或尚未就绪。
            请点击「启动运行环境」后重试。
            \(String(detail.suffix(800)))
            """
        }
    }
}
