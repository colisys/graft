import Foundation

/// How a preset application is installed inside the selected Linux base image.
public enum InstallStrategy: Hashable, Sendable {
    /// Debian/Ubuntu apt package(s).
    case apt([String])
    /// Architecture-specific `.deb` downloaded on the host.
    case directDeb(arm64: String, amd64: String, packageName: String)
    /// Configure Mozilla's official APT repository, then install packages.
    case mozillaRepository([String])
    /// Download Mozilla's official architecture-specific Firefox tarball and
    /// install it under `/opt/firefox` without touching the APT repository.
    case firefoxTarball(arm64: String, amd64: String)
    /// Arch Linux pacman package(s).
    case pacman([String])
    /// Alpine apk package(s).
    case apk([String])
}

/// A one-click installable Linux desktop application.
public struct PresetApp: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let summary: String
    public let symbolName: String
    /// Per-base installation plan. A missing key means the preset is not
    /// supported on that base image.
    public let installs: [BaseImage: InstallStrategy]
    /// Filename / executable fragments used to find the matching `.desktop`
    /// entries after installation.
    public let desktopHints: [String]

    public init(
        id: String,
        name: String,
        summary: String,
        symbolName: String,
        installs: [BaseImage: InstallStrategy],
        desktopHints: [String]
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.symbolName = symbolName
        self.installs = installs
        self.desktopHints = desktopHints
    }

    public func strategy(for baseImage: BaseImage) -> InstallStrategy? {
        installs[baseImage]
    }

    public var supportedBases: [BaseImage] {
        BaseImage.allCases.filter { installs[$0] != nil }
    }

    public var isElectronApp: Bool {
        ["vscode"].contains(id)
    }
}

public enum PresetCatalog {
    private static let vsCodePackageURLs = (
        arm64: "https://update.code.visualstudio.com/latest/linux-deb-arm64/stable",
        amd64: "https://update.code.visualstudio.com/latest/linux-deb-x64/stable"
    )

    private static let firefoxPackageURLs = (
        arm64: "https://download.mozilla.org/?product=firefox-latest-ssl&os=linux64-aarch64&lang=zh-CN",
        amd64: "https://download.mozilla.org/?product=firefox-latest-ssl&os=linux64&lang=zh-CN"
    )

    public static let all: [PresetApp] = [
        PresetApp(
            id: "vscode",
            name: "Visual Studio Code",
            summary: "微软官方 Linux 版；Ubuntu / Debian 使用 .deb，Arch 使用官方 code 包。",
            symbolName: "chevron.left.forwardslash.chevron.right",
            installs: [
                .ubuntu: .directDeb(arm64: vsCodePackageURLs.arm64, amd64: vsCodePackageURLs.amd64, packageName: "code"),
                .debian: .directDeb(arm64: vsCodePackageURLs.arm64, amd64: vsCodePackageURLs.amd64, packageName: "code"),
                .arch: .pacman(["code"])
            ],
            desktopHints: ["code", "visual-studio-code"]
        ),
        PresetApp(
            id: "firefox",
            name: "Firefox",
            summary: "官方 tar.xz 压缩包（Debian/Ubuntu）或发行版原生包（Arch/Alpine）。",
            symbolName: "globe",
            installs: [
                .ubuntu: .firefoxTarball(
                    arm64: firefoxPackageURLs.arm64,
                    amd64: firefoxPackageURLs.amd64
                ),
                .debian: .firefoxTarball(
                    arm64: firefoxPackageURLs.arm64,
                    amd64: firefoxPackageURLs.amd64
                ),
                .arch: .pacman(["firefox"]),
                .alpine: .apk(["firefox"])
            ],
            desktopHints: ["firefox"]
        ),
        PresetApp(
            id: "gimp",
            name: "GIMP",
            summary: "GNU 图像处理程序；各发行版均提供原生包。",
            symbolName: "photo",
            installs: [
                .ubuntu: .apt(["gimp"]),
                .debian: .apt(["gimp"]),
                .arch: .pacman(["gimp"]),
                .alpine: .apk(["gimp"])
            ],
            desktopHints: ["gimp"]
        ),
        PresetApp(
            id: "inkscape",
            name: "Inkscape",
            summary: "专业矢量绘图软件；各发行版均提供原生包。",
            symbolName: "scribble.variable",
            installs: [
                .ubuntu: .apt(["inkscape"]),
                .debian: .apt(["inkscape"]),
                .arch: .pacman(["inkscape"]),
                .alpine: .apk(["inkscape"])
            ],
            desktopHints: ["inkscape"]
        ),
        PresetApp(
            id: "krita",
            name: "Krita",
            summary: "开源数字绘画工具；Ubuntu / Debian / Arch 提供原生包。",
            symbolName: "paintbrush.pointed",
            installs: [
                .ubuntu: .apt(["krita"]),
                .debian: .apt(["krita"]),
                .arch: .pacman(["krita"])
            ],
            desktopHints: ["krita"]
        ),
        PresetApp(
            id: "vlc",
            name: "VLC",
            summary: "全能媒体播放器；各发行版均提供原生包。",
            symbolName: "play.rectangle",
            installs: [
                .ubuntu: .apt(["vlc"]),
                .debian: .apt(["vlc"]),
                .arch: .pacman(["vlc"]),
                .alpine: .apk(["vlc"])
            ],
            desktopHints: ["vlc"]
        )
    ]

    public static func preset(id: String) -> PresetApp? {
        all.first { $0.id == id }
    }
}
