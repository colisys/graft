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
    private let fileQueue: DispatchQueue
    private let fileURL: URL

    // Pending UI ring. Once full, nextSlot points at the oldest entry.
    private let pendingLock = NSLock()
    private var pending: [Entry] = []
    private var nextSlot = 0
    private var needsClear = false
    private var flushScheduled = false
    private let recordingLock = NSLock()
    private var recordingStorage = true

    public static var logFileURL: URL {
        SessionRegistry.logsDirectory.appendingPathComponent("graft.log")
    }

    public convenience init(maxEntries: Int = 3000) {
        self.init(maxEntries: maxEntries, fileURL: Self.logFileURL)
    }

    init(maxEntries: Int, fileURL: URL, fileQueue: DispatchQueue = DispatchQueue(label: "app.graft.logfile")) {
        self.maxEntries = max(100, maxEntries)
        self.fileURL = fileURL
        self.fileQueue = fileQueue
    }

    public func append(_ text: String, level: Level = .info) {
        guard shouldRecord else { return }

        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }

        pendingLock.lock()
        defer { pendingLock.unlock() }
        writeToDisk(lines, level: level)
        for line in lines.suffix(maxEntries) {
            let entry = Entry(level: level, text: line)
            if pending.count < maxEntries {
                pending.append(entry)
            } else {
                pending[nextSlot] = entry
                nextSlot = (nextSlot + 1) % maxEntries
            }
        }
        scheduleFlushLocked()
    }

    private func scheduleFlushLocked() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) {
            self.flush()
        }
    }

    private func flush() {
        pendingLock.lock()
        let batch = pending
        let start = nextSlot
        let clear = needsClear
        pending = []
        nextSlot = 0
        needsClear = false
        flushScheduled = false
        pendingLock.unlock()

        // Publish outside the lock: Combine subscribers can call back into the store.
        var updated = clear ? [] : Array(entries.suffix(maxEntries - batch.count))
        updated.append(contentsOf: batch[start...])
        updated.append(contentsOf: batch[..<start])
        entries = updated
    }

    private var shouldRecord: Bool {
        recordingLock.lock()
        defer { recordingLock.unlock() }
        return recordingStorage
    }

    /// Persistent log used to diagnose failed builds / VM shutdowns. File
    /// logging retains recorded lines even if the UI ring overflows or is cleared.
    private func writeToDisk(_ lines: [String], level: Level) {
        fileQueue.async { [url = fileURL] in
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
        pendingLock.lock()
        defer { pendingLock.unlock() }
        pending = []
        nextSlot = 0
        needsClear = true
        scheduleFlushLocked()
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
