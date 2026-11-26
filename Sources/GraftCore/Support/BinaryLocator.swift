import Foundation

/// Finds executables and application bundles without relying on the PATH of
/// the process that launched Graft (a Finder-launched `.app` has a very small
/// PATH, so Homebrew prefixes must be searched explicitly).
public enum BinaryLocator {
    public static let defaultSearchDirectories: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
        "/opt/local/sbin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
        "/opt/X11/bin"
    ]

    /// Directories searched for command line tools, including the current PATH.
    public static var searchDirectories: [String] {
        var directories = defaultSearchDirectories
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            directories.append(contentsOf: path.split(separator: ":").map(String.init))
        }
        var seen = Set<String>()
        return directories.filter { seen.insert($0).inserted }
    }

    /// Locate an executable by name.
    public static func find(_ name: String, extraDirectories: [String] = []) -> String? {
        let fileManager = FileManager.default
        for directory in extraDirectories + searchDirectories {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Locate an application bundle in the usual macOS locations.
    public static func findApp(named names: [String]) -> URL? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        let roots = [
            "/Applications",
            "/Applications/Utilities",
            "/Applications/MacPorts",
            "/Applications/MacPorts/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            home + "/Applications"
        ]
        for root in roots {
            for name in names {
                let candidate = URL(fileURLWithPath: root).appendingPathComponent(name)
                if fileManager.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }

    /// The LaunchServices registrar, used to refresh icons of generated bundles.
    public static var launchServicesRegister: String {
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    }
}
