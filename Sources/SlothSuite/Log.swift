import Cocoa
import Foundation

/// A rotating file log.
///
/// The previous implementation wrote to `/tmp/slothsuite.log`, which macOS
/// periodically reaps — a log you need after "something went wrong yesterday"
/// could simply be gone. Logs now live under `~/Library/Logs/SlothSuite`,
/// where the system keeps them.
///
/// Writes are serialised on a private queue and never block the main thread.
final class Log {
    static let shared = Log()

    private let queue = DispatchQueue(label: "slothsuite.log", qos: .utility)

    /// Reused across calls. The old code built a new `ISO8601DateFormatter`
    /// for every single line, which is pure main-thread churn.
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private let maxBytes = 1_500_000
    private var directory: URL
    private var fileURL: URL
    private var mirrorsToStderr = false

    private init() {
        let dir = PathTools.defaultLogDirectory()
        self.directory = dir
        self.fileURL = dir.appendingPathComponent("slothsuite.log")
        PathTools.ensureDirectory(dir)
    }

    /// Point the log at a specific directory (used by the config loader).
    func configure(directory: URL) {
        queue.sync {
            self.directory = directory
            self.fileURL = directory.appendingPathComponent("slothsuite.log")
            PathTools.ensureDirectory(directory)
        }
    }

    var logFileURL: URL { fileURL }

    /// Also echo to stderr — makes `--selftest` output visible in a terminal.
    func mirrorToStderr(_ enabled: Bool) {
        queue.sync { mirrorsToStderr = enabled }
    }

    func write(_ message: String) {
        queue.async { [weak self] in
            self?.append(message)
        }
    }

    /// Write and wait for the bytes to land — for the self-test, which
    /// exits the process and would otherwise lose the tail of the log.
    func writeSync(_ message: String) {
        queue.sync { [weak self] in
            self?.append(message)
        }
    }

    private func append(_ message: String) {
        let stamp = formatter.string(from: Date())
        let line = "[\(stamp)] \(message)\n"

        if mirrorsToStderr {
            FileHandle.standardError.write(Data(line.utf8))
        }

        guard let data = line.data(using: .utf8) else { return }

        PathTools.ensureDirectory(directory)

        // Rotate before the write so the file never grows past the cap.
        if let size = try? FileHandle(forWritingTo: fileURL).seekToEnd(), size > maxBytes {
            rotate()
        }

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }

        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(data)
    }

    private func rotate() {
        let archived = directory.appendingPathComponent("slothsuite.log.1")
        try? FileManager.default.removeItem(at: archived)
        try? FileManager.default.moveItem(at: fileURL, to: archived)
    }

    /// The tail of the log, newest last — used by the in-app log viewer.
    func tail(_ lines: Int = 200) -> [String] {
        queue.sync {
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
            let all = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            return Array(all.suffix(lines))
        }
    }
}
