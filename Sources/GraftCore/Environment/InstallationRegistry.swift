import Foundation

/// A persisted record of an application installed through the app store.
/// It keeps the Linux container/base image associated with the generated
/// macOS `.app`, so apps can be found and removed after restarts.
public struct InstalledApplication: Codable, Identifiable, Hashable, Sendable {
    public var presetID: String?
    public var name: String
    public var baseImage: BaseImage
    public var containerName: String
    public var bundlePath: String?
    public var desktopFile: String?
    public var installedAt: Date

    public var id: String {
        "\(containerName)|\(presetID ?? bundlePath ?? name)"
    }

    public init(
        presetID: String?,
        name: String,
        baseImage: BaseImage,
        containerName: String,
        bundlePath: String? = nil,
        desktopFile: String? = nil,
        installedAt: Date = Date()
    ) {
        self.presetID = presetID
        self.name = name
        self.baseImage = baseImage
        self.containerName = containerName
        self.bundlePath = bundlePath
        self.desktopFile = desktopFile
        self.installedAt = installedAt
    }
}

/// Small JSON-backed registry written to
/// `~/Library/Application Support/Graft/installations.json`.
public final class InstallationRegistry: @unchecked Sendable {
    public static let shared = InstallationRegistry()

    private let lock = NSLock()
    private var records: [InstalledApplication] = []
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? SessionRegistry.supportDirectory
            .appendingPathComponent("installations.json")
        load()
    }

    public func all() -> [InstalledApplication] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    public func upsert(_ record: InstalledApplication) {
        lock.lock()
        defer { lock.unlock() }
        if let index = records.firstIndex(where: {
            $0.containerName == record.containerName
                && ($0.presetID == record.presetID
                    || ($0.presetID == nil && $0.bundlePath == record.bundlePath))
        }) {
            records[index] = record
        } else {
            records.append(record)
        }
        saveLocked()
    }

    public func remove(id: String) {
        lock.lock()
        defer { lock.unlock() }
        records.removeAll { $0.id == id }
        saveLocked()
    }

    public func remove(presetID: String, containerName: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        records.removeAll { record in
            guard record.presetID == presetID else { return false }
            if let containerName { return record.containerName == containerName }
            return true
        }
        saveLocked()
    }

    public func remove(containerName: String) {
        lock.lock()
        defer { lock.unlock() }
        records.removeAll { $0.containerName == containerName }
        saveLocked()
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        records.removeAll()
        saveLocked()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        records = (try? JSONDecoder().decode([InstalledApplication].self, from: data)) ?? []
    }

    private func saveLocked() {
        let snapshot = records
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
