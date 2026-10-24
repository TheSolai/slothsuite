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

    /// Guards the state.
    ///
    /// The store is written from a background queue — a note has to reach
    /// the disk even while the main thread is busy — so the state it guards
    /// can be touched from two threads at once.
    private let lock = NSLock()

    /// The queue the file is written on.
    ///
    /// Writes are serialised, so the file is never half-written, and they do
    /// not run on the main thread, so a write cannot stutter the typing that
    /// caused it.
    private let writer = DispatchQueue(label: "com.amre.slothsuite.learning.write", qos: .utility)

    /// The write that has not happened yet, if a newer one has replaced it.
    private var pendingWrite: DispatchWorkItem?

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
    ///
    /// The write happens on a background queue, and a burst of changes
    /// collapses into one write: the newest state wins, and the file on disk
    /// is always the state the user last saw. Writing on the main thread
    /// instead would mean a keystroke waits for the disk.
    func save() {
        lock.lock()
        let snapshot = state
        pendingWrite?.cancel()
        let work = DispatchWorkItem { [weak self] in
            _ = self?.write(snapshot)
        }
        pendingWrite = work
        lock.unlock()

        writer.async(execute: work)
    }

    /// Write the state to disk right now, on this thread.
    ///
    /// The ordinary save is asynchronous, which is right for typing and
    /// wrong for quitting: an app that is on its way out has to leave the
    /// file complete before it goes. A write that is already on its way is
    /// waited out first, so the file cannot end up holding older state than
    /// the one being written now.
    func saveNow() {
        lock.lock()
        pendingWrite?.cancel()
        pendingWrite = nil
        let snapshot = state
        lock.unlock()

        writer.sync {}
        _ = write(snapshot)
    }

    /// Write a snapshot to disk. Runs on the writer queue.
    private func write(_ snapshot: LearningState) -> Bool {
        guard let data = try? JSONEncoder.pretty.encode(snapshot) else { return false }
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
        notifyChange()
    }

    /// Tell the interface that something changed.
    ///
    /// The interface belongs to the main thread, so the news is delivered
    /// there even when the change happened somewhere else.
    private func notifyChange() {
        let handler = onChange
        guard let handler else { return }
        if Thread.isMainThread {
            handler()
        } else {
            DispatchQueue.main.async(execute: handler)
        }
    }

    /// Read the state under the lock.
    private func withState<T>(_ body: (LearningState) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(state)
    }

    /// Change the state under the lock.
    private func mutate<T>(_ body: (inout LearningState) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    // MARK: Favourites

    func isFavourite(documentId: String) -> Bool {
        withState { $0.favourites.contains(documentId) }
    }

    func toggleFavourite(documentId: String) {
        mutate { state in
            if state.favourites.contains(documentId) {
                state.favourites.remove(documentId)
            } else {
                state.favourites.insert(documentId)
            }
        }
        commit()
    }

    // MARK: Read state

    func isRead(documentId: String) -> Bool {
        withState { $0.read.contains(documentId) }
    }

    func toggleRead(documentId: String) {
        mutate { state in
            if state.read.contains(documentId) {
                state.read.remove(documentId)
            } else {
                state.read.insert(documentId)
            }
        }
        commit()
    }

    var unreadCount: Int {
        withState { $0.read.count }
    }

    // MARK: Continue reading

    func markReading(documentId: String, chapter: Int = 0) {
        mutate { state in
            state.lastReadDocumentId = documentId
            state.lastReadChapter = chapter
        }
        commit()
    }

    var lastReadDocumentId: String? { withState { $0.lastReadDocumentId } }

    // MARK: Notes

    func notes(for documentId: String) -> [StudyNote] {
        withState { state in
            state.notes.filter { $0.documentId == documentId }
                .sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    var allNotes: [StudyNote] {
        withState { state in
            state.notes.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    func note(id: String) -> StudyNote? {
        withState { state in
            state.notes.first { $0.id == id }
        }
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
        mutate { $0.notes.append(note) }
        commit()
        return note
    }

    func updateNote(id: String, body: String) {
        let changed = mutate { state -> Bool in
            guard let index = state.notes.firstIndex(where: { $0.id == id }) else { return false }
            state.notes[index].body = body
            state.notes[index].updatedAt = Date()
            return true
        }
        guard changed else { return }
        commit()
    }

    func deleteNote(id: String) {
        mutate { $0.notes.removeAll { $0.id == id } }
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

        for note in withState({ $0.notes }) {
            let haystack = "\(note.documentTitle) \(note.body)".lowercased()
            if haystack.contains(needle) {
                results.append("Note — \(note.summaryLine)")
            }
        }

        return results
    }
}
