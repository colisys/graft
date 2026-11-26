import Foundation

/// Package manager available inside the selected Linux base image.
public enum LinuxPackageManager: String, CaseIterable, Identifiable, Sendable {
    case apt
    case pacman
    case apk
    case dnf

    public var id: String { rawValue }

    public var displayName: String { rawValue }

    public var installCommandName: String {
        switch self {
        case .apt: return "apt-get install"
        case .pacman: return "pacman -S"
        case .apk: return "apk add"
        case .dnf: return "dnf install"
        }
    }
}

/// Selectable Linux base image.
///
/// All images are built locally from a Dockerfile template; Graft does not
/// distribute any image. The choice changes the package manager, container
/// name and compatibility profile.
public enum BaseImage: String, CaseIterable, Identifiable, Codable, Sendable {
    case ubuntu
    case debian
    case arch
    case alpine
    case rocky

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ubuntu: return "Ubuntu 24.04"
        case .debian: return "Debian 12"
        case .arch: return "Arch Linux"
        case .alpine: return "Alpine Linux"
                case .rocky: return "Rocky Linux 9（CentOS 下游）"
        }
    }

    public var shortName: String {
        switch self {
        case .ubuntu: return "Ubuntu"
        case .debian: return "Debian"
        case .arch: return "Arch"
        case .alpine: return "Alpine"
                case .rocky: return "Rocky"
        }
    }

    public var version: String {
        switch self {
        case .ubuntu: return "24.04"
        case .debian: return "12"
        case .arch: return "rolling"
        case .alpine: return "3.20"
                case .rocky: return "9"
        }
    }

    public var detail: String {
        switch self {
        case .ubuntu:
            return "兼容性最佳；apt 依赖较多，适合大多数 Electron 与官方 .deb 应用。"
        case .debian:
            return "比 Ubuntu 更精简的 glibc 环境，仍兼容官方 .deb 与 Electron。"
        case .arch:
            return "轻量滚动发行版，使用 pacman；适合愿意自行处理依赖的用户。"
        case .alpine:
            return "体积最小，使用 musl libc；官方 Electron 与 .deb 应用兼容性有限。"
                    case .rocky:
                        return "企业 Linux 9 兼容环境，使用 DNF 管理 RPM 软件包。"
        }
    }

    public var compatibilityNote: String? {
        switch self {
        case .alpine:
            return "Alpine 使用 musl libc。VS Code 等官方 glibc / Electron 应用可能无法运行；请优先使用 Alpine 原生包。"
        case .arch:
            return "Arch 使用 pacman，不支持官方 .deb；预设应用会改用 Arch 官方包。"
        case .rocky:
            return "Rocky 使用 RPM 而非 .deb；请使用 Rocky 9 软件源中的原生包。"
        default:
            return nil
        }
    }

    public var packageManager: LinuxPackageManager {
        switch self {
        case .ubuntu, .debian: return .apt
        case .arch: return .pacman
        case .alpine: return .apk
                case .rocky: return .dnf
        }
    }

    public var isDebianBased: Bool {
        self == .ubuntu || self == .debian
    }

    /// Alpine/musl cannot run most official glibc Electron builds. The preset
    /// catalog still exposes only native musl packages on Alpine.
    public var supportsElectronBuilds: Bool {
        self != .alpine
    }

    public var baseImageReference: String {
        switch self {
        case .ubuntu: return "ubuntu:24.04"
        case .debian: return "debian:12-slim"
        case .arch: return "archlinux:latest"
        case .alpine: return "alpine:3.20"
                case .rocky: return "rockylinux/rockylinux:9"
        }
    }

    public func baseImageReference(registryMirror: String) -> String {
        DockerRegistry.reference(prefix: registryMirror, image: baseImageReference)
    }

    public func dockerfile(registryMirror: String) -> String {
        BuiltinDockerfile.template(for: self, registryMirror: registryMirror)
    }

    /// Dockerfile using the official Docker Hub reference (no mirror).
    public var defaultDockerfile: String {
        BuiltinDockerfile.template(for: self)
    }

    public var imageName: String {
        switch self {
        case .ubuntu: return "graft/ubuntu-desktop:24.04"
        case .debian: return "graft/debian-desktop:12"
        case .arch: return "graft/arch-desktop:latest"
        case .alpine: return "graft/alpine-desktop:3.20"
                case .rocky: return "graft/rocky-desktop:9"
        }
    }

    public var containerName: String {
        switch self {
        case .ubuntu: return "graft-runtime"
        case .debian: return "graft-runtime-debian"
        case .arch: return "graft-runtime-arch"
        case .alpine: return "graft-runtime-alpine"
                case .rocky: return "graft-runtime-rocky"
        }
    }

    public var homeVolumeName: String {
        switch self {
        case .ubuntu: return "graft-home"
        case .debian: return "graft-home-debian"
        case .arch: return "graft-home-arch"
        case .alpine: return "graft-home-alpine"
                case .rocky: return "graft-home-rocky"
        }
    }

    public var localeEnvironment: [String: String] {
        switch self {
        case .alpine:
            return ["LANG": "C.UTF-8", "LC_ALL": "C.UTF-8"]
        default:
            return ["LANG": "zh_CN.UTF-8", "LC_ALL": "zh_CN.UTF-8"]
        }
    }

    public var packagePlaceholder: String {
        switch self {
        case .ubuntu, .debian:
            return "例如：thunderbird、libreoffice-gtk3"
        case .arch:
            return "例如：firefox、gimp、code"
        case .alpine:
            return "例如：firefox、gimp、vlc"
                    case .rocky:
                        return "例如：firefox、thunderbird"
        }
    }

    /// Packages installed on demand before a source build.
    public var buildDependencies: [String] {
        switch self {
        case .ubuntu, .debian:
            return [
                "build-essential", "git", "cmake", "meson", "ninja-build",
                "pkg-config", "autoconf", "automake", "libtool"
            ]
        case .arch:
            return [
                "base-devel", "git", "cmake", "meson", "ninja",
                "pkgconf", "autoconf", "automake", "libtool"
            ]
        case .rocky:
            return [
                "gcc", "gcc-c++", "make", "git", "cmake", "meson", "ninja-build",
                "pkgconf-pkg-config", "autoconf", "automake", "libtool"
            ]
        case .alpine:
            return [
                "build-base", "git", "cmake", "meson", "ninja",
                "pkgconf", "autoconf", "automake", "libtool"
            ]
        }
    }
}

/// Rewrites Docker Hub image references to a configurable registry mirror.
/// Only the `FROM` image of the base Dockerfile is affected; Graft-built image
/// tags stay local.
public enum DockerRegistry {
    public static func normalizePrefix(_ input: String) -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("https://") {
            value.removeFirst("https://".count)
        } else if value.hasPrefix("http://") {
            value.removeFirst("http://".count)
        }
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    public static func reference(prefix: String, image: String) -> String {
        let normalized = normalizePrefix(prefix)
        guard !normalized.isEmpty else { return image }

        let components = image.split(separator: "/").map(String.init)
        if components.count > 1 {
            let first = components[0]
            if first.contains(".") || first.contains(":") || first == "localhost" {
                return image
            }
            return "\(normalized)/\(image)"
        }
        return "\(normalized)/library/\(image)"
    }
}


/// Thread-safe holder for the selected base image so the container layer can
/// read the current selection without hopping to the main actor.
public final class RuntimeSettings: @unchecked Sendable {
    public static let shared = RuntimeSettings()

    private let lock = NSLock()
    private var storage: BaseImage = .ubuntu
    private var environmentNameStorage: String = ""
    private var mirrorStorage: String = ""
    private var electronGPUStorage = false
    private var xquartzIGLXStorage = false
    private var displayScaleStorage = 1

    public init() {}

    public var baseImage: BaseImage {
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

    /// Empty selects the legacy default container; named environments have their own home volume.
    public var environmentName: String {
        get { lock.lock(); defer { lock.unlock() }; return environmentNameStorage }
        set { lock.lock(); environmentNameStorage = newValue; lock.unlock() }
    }

    /// Optional Docker registry prefix used when pulling the base image.
    /// Empty means Docker Hub.
    public var registryMirror: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return mirrorStorage
        }
        set {
            lock.lock()
            mirrorStorage = newValue
            lock.unlock()
        }
    }

    /// Experimental: omit `--disable-gpu` for Electron apps.
    public var electronGPUEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return electronGPUStorage
        }
        set {
            lock.lock()
            electronGPUStorage = newValue
            lock.unlock()
        }
    }

    /// Application-side logical scale. Existing processes and wrappers are unaffected.
    public var displayScale: Int {
        get { lock.lock(); defer { lock.unlock() }; return displayScaleStorage }
        set { lock.lock(); displayScaleStorage = newValue == 2 ? 2 : 1; lock.unlock() }
    }

    /// XQuartz `enable_iglx` (indirect GLX), only useful for OpenGL apps.
    public var xquartzIGLXEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return xquartzIGLXStorage
        }
        set {
            lock.lock()
            xquartzIGLXStorage = newValue
            lock.unlock()
        }
    }
}
