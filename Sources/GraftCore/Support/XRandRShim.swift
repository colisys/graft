import Foundation

/// Locates and installs the small Linux `LD_PRELOAD` shim that rewrites
/// XRandR refresh rates. XQuartz's rootless mode hard-codes a 1 Hz fake mode;
/// the shim makes X11 clients see the selected macOS refresh rate instead.
public enum XRandRShim {
    public static let containerPath = "/usr/local/lib/libgraft-xrandr-refresh.so"

    public static var installedDirectory: URL {
        SessionRegistry.supportDirectory.appendingPathComponent("Shims", isDirectory: true)
    }

    public static func fileName(
        for base: BaseImage,
        architecture: HostArchitecture = .current
    ) -> String {
        let arch = architecture == .arm64 ? "arm64" : "amd64"
        let libc = base == .alpine ? "musl" : "glibc"
        return "libgraft-xrandr-refresh-linux-\(arch)-\(libc).so"
    }

    private static var bundledDirectories: [URL] {
        var directories: [URL] = []
        if let resources = Bundle.main.resourceURL {
            directories.append(resources.appendingPathComponent("Shims", isDirectory: true))
        }
        directories.append(
            Bundle.main.bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("Shims", isDirectory: true)
        )
        directories.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("Shims", isDirectory: true)
        )
        return directories
    }

    public static func bundledURL(
        for base: BaseImage,
        architecture: HostArchitecture = .current
    ) -> URL? {
        let name = fileName(for: base, architecture: architecture)
        for directory in bundledDirectories {
            let candidate = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    public static func installedURL(
        for base: BaseImage,
        architecture: HostArchitecture = .current
    ) -> URL? {
        let candidate = installedDirectory.appendingPathComponent(
            fileName(for: base, architecture: architecture)
        )
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// Returns a stable Application Support path, copying the bundled shim
    /// first when necessary.
    public static func hostURL(
        for base: BaseImage,
        architecture: HostArchitecture = .current
    ) -> URL? {
        installBundledShims()
        if let installed = installedURL(for: base, architecture: architecture) {
            return installed
        }
        return bundledURL(for: base, architecture: architecture)
    }

    public static func isAvailable(for base: BaseImage) -> Bool {
        hostURL(for: base) != nil
    }

    /// Copies the bundled `.so` files to Application Support. Existing files
    /// with the same size are left untouched.
    @discardableResult
    public static func installBundledShims() -> Int {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: installedDirectory,
            withIntermediateDirectories: true
        )

        var copied = 0
        for directory in bundledDirectories {
            guard let urls = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for source in urls where source.pathExtension == "so" {
                let destination = installedDirectory.appendingPathComponent(source.lastPathComponent)
                let sourceSize = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
                let destinationSize = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
                if sourceSize == destinationSize, destinationSize >= 0 {
                    continue
                }
                try? fileManager.removeItem(at: destination)
                if (try? fileManager.copyItem(at: source, to: destination)) != nil {
                    copied += 1
                }
            }
        }
        return copied
    }
}
