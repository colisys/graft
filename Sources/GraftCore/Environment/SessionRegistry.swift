import Foundation
import Darwin

/// A GUI application session started by one of the generated launcher scripts.
public struct GraftSession: Identifiable, Sendable {
    public let id: String
    public let pid: Int32
    public let startedAt: Date
    public let appName: String

    public init(id: String, pid: Int32, startedAt: Date, appName: String) {
        self.id = id
        self.pid = pid
        self.startedAt = startedAt
        self.appName = appName
    }
}

/// Tracks launcher processes using marker files.
///
/// Generated `.app` launchers write a marker while they wait for the Linux
/// process, and remove it on exit. `EnvironmentManager` counts these markers to
/// decide when Colima has been idle long enough to be suspended. Because the
/// markers live on disk, the idle logic also works when Graft itself was
/// restarted while applications were running.
public enum SessionRegistry {
    public static var supportDirectory: URL {
        let base: URL
        if let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            base = url
        } else {
            base = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        }
        return base.appendingPathComponent("Graft", isDirectory: true)
    }

    public static var sessionsDirectory: URL {
        supportDirectory.appendingPathComponent("sessions", isDirectory: true)
    }

    public static var logsDirectory: URL {
        supportDirectory.appendingPathComponent("logs", isDirectory: true)
    }

    public static func prepare() {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
    }

    /// Marker format written by launchers: `pid<TAB>unix-timestamp<TAB>appName`.
    public static func activeSessions() -> [GraftSession] {
        prepare()
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var sessions: [GraftSession] = []

        for file in files where file.pathExtension == "session" {
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else {
                try? fileManager.removeItem(at: file)
                continue
            }
            let fields = contents
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\t", omittingEmptySubsequences: false)
                .map(String.init)
            guard fields.count >= 2,
                  let pid = Int32(fields[0]),
                  let timestamp = TimeInterval(fields[1]) else {
                try? fileManager.removeItem(at: file)
                continue
            }
            let startedAt = Date(timeIntervalSince1970: timestamp)
            guard isProcessAlive(pid) else {
                try? fileManager.removeItem(at: file)
                continue
            }
            sessions.append(
                GraftSession(
                    id: file.lastPathComponent,
                    pid: pid,
                    startedAt: startedAt,
                    appName: fields.count > 2 ? fields[2] : file.deletingPathExtension().lastPathComponent
                )
            )
        }

        return sessions.sorted { $0.startedAt < $1.startedAt }
    }

    public static func activeCount() -> Int {
        activeSessions().count
    }

    /// Creates a marker for an application launched directly from the Graft
    /// UI (as opposed to a generated `.app` whose launcher owns its marker).
    @discardableResult
    public static func createMarker(id: String, pid: Int32 = getpid(), appName: String) -> URL? {
        prepare()
        let safeID = id
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        let url = sessionsDirectory.appendingPathComponent("\(safeID).\(pid).session")
        let contents = "\(pid)\t\(Int(Date().timeIntervalSince1970))\t\(appName)\n"
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    public static func removeMarker(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
