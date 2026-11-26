import Foundation

/// The CPU architecture of the macOS host.
///
/// Graft never bundles Linux binaries: the architecture is used only to pick
/// the matching container platform (`linux/arm64` vs `linux/x86_64`) and the
/// matching `.deb` download for a preset application.
public enum HostArchitecture: String, Sendable, CaseIterable {
    case arm64
    case x86_64

    public static var current: HostArchitecture {
        if let override = ProcessInfo.processInfo.environment["GRAFT_HOST_ARCH"],
           let architecture = HostArchitecture(rawValue: override) {
            return architecture
        }
        #if arch(arm64)
        return .arm64
        #else
        return .x86_64
        #endif
    }

    /// Docker platform string used for builds and `docker run`.
    public var dockerPlatform: String {
        self == .arm64 ? "linux/arm64" : "linux/amd64"
    }

    /// Debian architecture string used when downloading `.deb` packages.
    public var debArchitecture: String {
        self == .arm64 ? "arm64" : "amd64"
    }

    public var displayName: String {
        switch self {
        case .arm64: return "Apple Silicon (arm64)"
        case .x86_64: return "Intel (x86_64)"
        }
    }
}

/// Hardware information used to size the Colima virtual machine.
public struct HostResources: Sendable {
    public let architecture: HostArchitecture
    public let cpuCount: Int
    public let physicalMemoryBytes: UInt64

    public init(architecture: HostArchitecture, cpuCount: Int, physicalMemoryBytes: UInt64) {
        self.architecture = architecture
        self.cpuCount = cpuCount
        self.physicalMemoryBytes = physicalMemoryBytes
    }

    public static var current: HostResources {
        HostResources(
            architecture: .current,
            cpuCount: max(1, ProcessInfo.processInfo.activeProcessorCount),
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
        )
    }

    /// Leave at least one host core for macOS; cap the VM at 4 vCPUs.
    public var recommendedColimaCPU: Int {
        min(4, max(2, cpuCount - 1))
    }

    /// 4 GiB is the practical minimum for Electron apps in a GUI container;
    /// very small hosts get 2 GiB so macOS remains usable.
    public var recommendedColimaMemoryGB: Int {
        let gigabytes = Int(physicalMemoryBytes / 1_073_741_824)
        return gigabytes >= 8 ? 4 : 2
    }

    public var formattedPhysicalMemory: String {
        ByteCountFormatter.string(fromByteCount: Int64(physicalMemoryBytes), countStyle: .memory)
    }
}
