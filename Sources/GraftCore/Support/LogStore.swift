import Foundation
import Combine

/// In-memory ring buffer of log lines shown in the UI.
///
/// `append` may be called from any thread (process pipes, background tasks);
/// mutations of the published array are always performed on the main queue.
public final class LogStore: ObservableObject, @unchecked Sendable {
    public enum Level: String, Sendable, CaseIterable {
        case info
        case command
        case success
        case warning
        case error
    }

    public struct Entry: Identifiable, Sendable {
        public let id: UUID
        public let date: Date
        public let level: Level
        public let text: String

        public init(id: UUID = UUID(), date: Date = Date(), level: Level, text: String) {
            self.id = id
            self.date = date
            self.level = level
            self.text = text
        }
    }

    @Published public private(set) var entries: [Entry] = []
    @Published public var isRecording = true {
        didSet {
            recordingLock.lock()
            recordingStorage = isRecording
            recordingLock.unlock()
        }
    }

    private let maxEntries: Int
    private let fileQueue = DispatchQueue(label: "app.graft.logfile")
    private let recordingLock = NSLock()
    private var recordingStorage = true

    public static var logFileURL: URL {
        SessionRegistry.logsDirectory.appendingPathComponent("graft.log")
    }

    public init(maxEntries: Int = 3000) {
        self.maxEntries = max(100, maxEntries)
    }

    public func append(_ text: String, level: Level = .info) {
        guard shouldRecord else { return }

        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }

        writeToDisk(lines, level: level)

        DispatchQueue.main.async {
            for line in lines {
                self.entries.append(Entry(level: level, text: line))
            }
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
        }
    }

    private var shouldRecord: Bool {
        recordingLock.lock()
        defer { recordingLock.unlock() }
        return recordingStorage
    }

    /// Persistent log used to diagnose failed builds / VM shutdowns. File
    /// logging continues even when the UI log is paused.
    private func writeToDisk(_ lines: [String], level: Level) {
        fileQueue.async {
            let url = Self.logFileURL
            let fileManager = FileManager.default
            try? fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
               let size = attributes[.size] as? NSNumber,
               size.intValue > 4_000_000 {
                try? fileManager.removeItem(at: url)
            }

            let stamp = Self.fileFormatter.string(from: Date())
            let payload = lines
                .map { "[\(stamp)] [\(level.rawValue.uppercased())] \($0)\n" }
                .joined()

            if !fileManager.fileExists(atPath: url.path) {
                fileManager.createFile(atPath: url.path, contents: nil)
            }

            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                try? handle.write(contentsOf: Data(payload.utf8))
            } else {
                try? Data(payload.utf8).write(to: url)
            }
        }
    }

    public func command(_ executable: String, _ arguments: [String]) {
        append("$ " + ShellQuote.command(executable, arguments), level: .command)
    }

    public func clear() {
        DispatchQueue.main.async {
            self.entries.removeAll()
        }
    }

    public func exportText() -> String {
        entries
            .map { entry in
                let stamp = Self.formatter.string(from: entry.date)
                return "[\(stamp)] [\(entry.level.rawValue.uppercased())] \(entry.text)"
            }
            .joined(separator: "\n")
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let fileFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
