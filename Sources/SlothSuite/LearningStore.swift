import Cocoa
import Foundation

// MARK: - Notes

/// A note the user wrote, anchored to a document.
///
/// Notes are the first thing that turns a library into a learning desk: the
/// books are what you read, the notes are what you keep.
struct StudyNote: Codable, Identifiable, Equatable {
    var id: String
    var documentId: String
    var documentTitle: String
    var body: String
    var createdAt: Date
    var updatedAt: Date

    /// The first line, for a list row.
    var preview: String {
        let first = body.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return first.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A one-line summary, for the command palette.
    var summaryLine: String {
        let text = preview.isEmpty ? "(empty note)" : preview
        return "\(documentTitle) — \(text)"
    }
}

// MARK: - Learning state

/// Everything the suite remembers about how the user is learning.
///
/// This is deliberately stored on the machine, next to the config, and
/// nowhere else. No account, no sync, no telemetry.
struct LearningState: Codable, Equatable {
    /// Documents the user starred.
    var favourites: Set<String> = []
    /// Documents the user has marked as read.
    var read: Set<String> = []
    /// The document the user was last reading.
    var lastReadDocumentId: String?
    /// The chapter the user was last reading inside it.
    var lastReadChapter: Int = 0
    /// Notes, newest last.
    var notes: [StudyNote] = []
}

// MARK: - Store

/// The suite's own memory: favourites, read state and notes.
///
/// Persisted as JSON in Application Support so it survives a restart and
/// can be inspected or backed up by hand.
final class LearningStore {
    static let shared = LearningStore()

    /// Fired whenever anything in the store changes.
    var onChange: (() -> Void)?

    private(set) var state = LearningState()

    private var fileURL: URL {
        PathTools.applicationSupportDirectory().appendingPathComponent("learning.json")
    }

    private init() {
        load()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            state = try JSONDecoder().decode(LearningState.self, from: data)
        } catch {
            Log.shared.write("could not read learning.json: \(error)")
            state = LearningState()
        }
    }

    /// Write the state to disk. Called after every mutation.
    @discardableResult
    func save() -> Bool {
        guard let data = try? JSONEncoder.pretty.encode(state) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            Log.shared.write("could not save learning.json: \(error)")
            return false
        }
    }

    private func commit() {
        save()
        onChange?()
    }

    // MARK: Favourites

    func isFavourite(documentId: String) -> Bool {
        state.favourites.contains(documentId)
    }

    func toggleFavourite(documentId: String) {
        if state.favourites.contains(documentId) {
            state.favourites.remove(documentId)
        } else {
            state.favourites.insert(documentId)
        }
        commit()
    }

    // MARK: Read state

    func isRead(documentId: String) -> Bool {
        state.read.contains(documentId)
    }

    func toggleRead(documentId: String) {
        if state.read.contains(documentId) {
            state.read.remove(documentId)
        } else {
            state.read.insert(documentId)
        }
        commit()
    }

    var unreadCount: Int {
        state.read.count
    }

    // MARK: Continue reading

    func markReading(documentId: String, chapter: Int = 0) {
        state.lastReadDocumentId = documentId
        state.lastReadChapter = chapter
        commit()
    }

    var lastReadDocumentId: String? { state.lastReadDocumentId }

    // MARK: Notes

    func notes(for documentId: String) -> [StudyNote] {
        state.notes.filter { $0.documentId == documentId }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var allNotes: [StudyNote] {
        state.notes.sorted { $0.updatedAt > $1.updatedAt }
    }

    func note(id: String) -> StudyNote? {
        state.notes.first { $0.id == id }
    }

    /// Create a note, optionally anchored to a document.
    @discardableResult
    func addNote(documentId: String? = nil, documentTitle: String = "", body: String = "") -> StudyNote {
        let now = Date()
        let note = StudyNote(
            id: UUID().uuidString,
            documentId: documentId ?? "",
            documentTitle: documentTitle,
            body: body,
            createdAt: now,
            updatedAt: now
        )
        state.notes.append(note)
        commit()
        return note
    }

    func updateNote(id: String, body: String) {
        guard let index = state.notes.firstIndex(where: { $0.id == id }) else { return }
        state.notes[index].body = body
        state.notes[index].updatedAt = Date()
        commit()
    }

    func deleteNote(id: String) {
        state.notes.removeAll { $0.id == id }
        commit()
    }

    /// Search notes and documents for the command palette.
    func search(_ query: String, in documents: [LibraryDocument]) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }

        var results: [String] = []

        for document in documents {
            let haystack = "\(document.title) \(document.author) \(document.filename)".lowercased()
            if haystack.contains(needle) {
                results.append("Open “\(document.title)”")
            }
        }

        for note in state.notes {
            let haystack = "\(note.documentTitle) \(note.body)".lowercased()
            if haystack.contains(needle) {
                results.append("Note — \(note.summaryLine)")
            }
        }

        return results
    }
}
