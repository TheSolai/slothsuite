import Cocoa
import Foundation

// MARK: - Colours

extension NSColor {
    /// Build a colour from a `#RRGGBB` / `#RRGGBBAA` string.
    ///
    /// `NSColor` is not `Codable`, so the config file stores hex strings and
    /// the app converts them at load time.
    convenience init?(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6 || cleaned.count == 8,
              let value = UInt32(cleaned, radix: 16) else { return nil }

        let r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat
        if cleaned.count == 8 {
            r = CGFloat((value >> 24) & 0xFF) / 255
            g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >> 8) & 0xFF) / 255
            a = CGFloat(value & 0xFF) / 255
        } else {
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
            a = 1
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

// MARK: - Paths

enum PathTools {
    /// Expand a leading `~` to the user's home directory.
    static func expandingTilde(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "~" { return NSHomeDirectory() }
        if trimmed.hasPrefix("~/") {
            return NSHomeDirectory() + String(trimmed.dropFirst(2))
        }
        return trimmed
    }

    static func applicationSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("SlothSuite")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func defaultLogDirectory() -> URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return base.appendingPathComponent("Logs/SlothSuite")
    }

    /// Create a directory (and intermediates) if it is not already there.
    @discardableResult
    static func ensureDirectory(_ url: URL) -> Bool {
        (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil
    }
}

// MARK: - Small helpers

enum JSONTools {
    /// Turn a `JSONSerialization` object into a plain Swift dictionary.
    static func dictionary(from data: Data) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return nil }
        return dict
    }
}

extension String {
    /// Truncate for display without cutting a word in half mid-word.
    func trimmed(to limit: Int) -> String {
        guard count > limit else { return self }
        let slice = prefix(limit)
        if let space = slice.lastIndex(of: " ") {
            return String(slice[..<space]) + "…"
        }
        return String(slice) + "…"
    }
}
