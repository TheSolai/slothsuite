import Cocoa
import Foundation

/// Writes a briefing out as a set of separate files.
///
/// The old export produced one Markdown file with every chapter concatenated
/// — for a 66-chapter book that is a single unreadable document. The new
/// export writes one file per chapter plus an index, the audio scripts and
/// the sources, into a folder the user picks.
enum Exporter {

    struct File {
        let name: String
        let content: String
    }

    enum ExportError: LocalizedError {
        case noFiles
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .noFiles:
                return "There was nothing to export — no completed briefing was found."
            case .writeFailed(let message):
                return message
            }
        }
    }

    /// Ask for a destination folder and write the files into it.
    static func write(files: [File], suggestedName: String,
                      completion: @escaping (Result<URL, Error>) -> Void) {
        guard !files.isEmpty else {
            completion(.failure(ExportError.noFiles))
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for the exported briefing."
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first

        panel.begin { response in
            guard response == .OK, let folder = panel.url else {
                completion(.failure(ExportError.noFiles))
                return
            }

            let target = folder.appendingPathComponent(suggestedName)
            do {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            } catch {
                completion(.failure(ExportError.writeFailed(
                    "Could not create \(target.lastPathComponent): \(error.localizedDescription)")))
                return
            }

            var written = 0
            for file in files {
                let name = Self.uniqueName(for: file.name, in: target)
                let url = target.appendingPathComponent(name)
                do {
                    try file.content.write(to: url, atomically: true, encoding: .utf8)
                    written += 1
                } catch {
                    Log.shared.write("export failed for \(name): \(error)")
                }
            }

            guard written > 0 else {
                completion(.failure(ExportError.writeFailed("No files could be written.")))
                return
            }

            Log.shared.write("exported \(written) files to \(target.path)")
            completion(.success(target))
        }
    }

    /// Make a filename safe for the filesystem, and unique within the folder.
    static func uniqueName(for raw: String, in folder: URL) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.replacingOccurrences(of: "/", with: "-")
        name = name.replacingOccurrences(of: "\\", with: "-")
        name = name.replacingOccurrences(of: ":", with: "-")
        name = name.replacingOccurrences(of: "*", with: "-")
        name = name.replacingOccurrences(of: "?", with: "-")
        name = name.replacingOccurrences(of: "\"", with: "-")
        name = name.replacingOccurrences(of: "<", with: "-")
        name = name.replacingOccurrences(of: ">", with: "-")
        name = name.replacingOccurrences(of: "|", with: "-")
        name = name.replacingOccurrences(of: "\n", with: " ")
        while name.contains("  ") { name = name.replacingOccurrences(of: "  ", with: " ") }
        if name.hasPrefix(".") { name = "_" + name }
        if name.isEmpty { name = "untitled.md" }
        if name.count > 80 { name = String(name.prefix(80)) }
        if !name.lowercased().hasSuffix(".md") { name += ".md" }

        // Two chapters can share a title, so the index is kept unique.
        var candidate = name
        var counter = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            candidate = "\(base) (\(counter)).\(ext)"
            counter += 1
        }
        return candidate
    }

    /// A folder name for an exported briefing.
    static func folderName(for title: String) -> String {
        var name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.replacingOccurrences(of: "/", with: "-")
        name = name.replacingOccurrences(of: ":", with: "-")
        while name.contains("  ") { name = name.replacingOccurrences(of: "  ", with: " ") }
        if name.count > 60 { name = String(name.prefix(60)) }
        return name.isEmpty ? "SlothRead Export" : name
    }
}
