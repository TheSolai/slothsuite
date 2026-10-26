import Cocoa
import Foundation

// MARK: - Notes

/// A note the user wrote, anchored to a document.
struct StudyNote: Codable, Identifiable, Equatable {
    var id: String
    var documentId: String
    var documentTitle: String
    var body: String
    var createdAt: Date
    var updatedAt: Date
    /// The chapter the note was taken from.
    ///
    /// Zero is the overview that comes before the first chapter. Notes made
    /// before this was recorded simply have no chapter, and are treated as
    /// belonging to the overview.
    var chapter: Int = 0

    init(id: String,
         documentId: String,
         documentTitle: String,
         body: String,
         createdAt: Date,
         updatedAt: Date,
         chapter: Int = 0) {
        self.id = id
        self.documentId = documentId
        self.documentTitle = documentTitle
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.chapter = chapter
    }

    /// Read a note written by an older version of the suite.
    ///
    /// The chapter was not recorded then, so it is read as zero rather than
    /// failing — a note that cannot be read would take the whole file with
    /// it, and with it every other note.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        documentId = try container.decodeIfPresent(String.self, forKey: .documentId) ?? ""
        documentTitle = try container.decodeIfPresent(String.self, forKey: .documentTitle) ?? ""
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        chapter = try container.decodeIfPresent(Int.self, forKey: .chapter) ?? 0
    }

    enum CodingKeys: String, CodingKey {
        case id, documentId, documentTitle, body, createdAt, updatedAt, chapter
    }

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

    /// Where this note came from, in words.
    var chapterLabel: String {
        chapter > 0 ? "Chapter \(chapter)" : "Overview"
    }
}

// MARK: - Reading position

/// Where the reader had got to in a document.
struct ReadingPosition: Codable, Equatable {
    /// The chapter. Zero is the overview before the first chapter.
    var chapter: Int = 0
    /// How far down that chapter the reader had got, from 0 to 1.
    var scroll: Double = 0
    /// When it was last read.
    var updatedAt: Date = Date()
}

// MARK: - Review

/// How a note is going in spaced repetition.
struct ReviewState: Codable, Equatable {
    /// How many times in a row the note has been remembered.
    var repetitions: Int = 0
    /// When it is next due.
    var dueAt: Date = Date()
    /// When it was last answered.
    var lastReviewedAt: Date?
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
    /// Where the reader had got to in each document.
    var positions: [String: ReadingPosition] = [:]
    /// The spaced-repetition state of each note.
    var reviews: [String: ReviewState] = [:]

    init() {}

    /// Read a file written by an older version of the suite.
    ///
    /// Everything the file does not have is simply empty. A file that cannot
    /// be read at all would throw away the user's notes, so the parts that
    /// are new are the parts that are allowed to be missing.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        favourites = try container.decodeIfPresent(Set<String>.self, forKey: .favourites) ?? []
        read = try container.decodeIfPresent(Set<String>.self, forKey: .read) ?? []
        lastReadDocumentId = try container.decodeIfPresent(String.self, forKey: .lastReadDocumentId)
        lastReadChapter = try container.decodeIfPresent(Int.self, forKey: .lastReadChapter) ?? 0
        notes = try container.decodeIfPresent([StudyNote].self, forKey: .notes) ?? []
        positions = try container.decodeIfPresent([String: ReadingPosition].self, forKey: .positions) ?? [:]
        reviews = try container.decodeIfPresent([String: ReviewState].self, forKey: .reviews) ?? [:]
    }

    enum CodingKeys: String, CodingKey {
        case favourites, read, lastReadDocumentId, lastReadChapter, notes, positions, reviews
    }
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

    // MARK: Continue reading

    func markReading(documentId: String, chapter: Int = 0) {
        mutate { state in
            state.lastReadDocumentId = documentId
            // The briefing is the front of the book, not a place in it. A book
            // that opens on its briefing must not forget the chapter the
            // reader was last in.
            if chapter > 0 { state.lastReadChapter = chapter }
        }
        commit()
    }

    /// A copy of the whole store.
    ///
    /// The self-test reads books, writes places and makes notes. Anything
    /// it leaves behind is litter in the reader's own data, so the store
    /// is taken as it was before the test and put back afterwards.
    func snapshotState() -> LearningState {
        withState { $0 }
    }

    /// Put the whole store back, as it was.
    func restoreState(_ saved: LearningState) {
        mutate { state in
            state = saved
        }
        commit()
    }

    /// Put the "continue reading" pointer back where it was.
    ///
    /// The pointer says which book the reader opens next, so it has to
    /// be put back exactly as it was — including being put back to
    /// *nothing*, which is what it is for a reader who has not opened a
    /// book yet. The self-test writes to it while it checks that every
    /// document keeps its own place, and without this a test run leaves
    /// the reader pointing at a document that was never in the library.
    func restoreLastRead(documentId: String?, chapter: Int) {
        mutate { state in
            state.lastReadDocumentId = documentId
            state.lastReadChapter = chapter
        }
        commit()
    }

    var lastReadDocumentId: String? { withState { $0.lastReadDocumentId } }

    /// The chapter of the last-read document the reader was on.
    var lastReadChapter: Int { withState { $0.lastReadChapter } }

    // MARK: Reading position

    /// Where the reader had got to in a document.
    ///
    /// Every document keeps its own place. Remembering only the last one
    /// meant that reading a second book lost your place in the first.
    func position(for documentId: String) -> ReadingPosition? {
        withState { $0.positions[documentId] }
    }

    var allPositions: [String: ReadingPosition] {
        withState { $0.positions }
    }

    /// Remember where the reader is in a document.
    ///
    /// The scroll is a fraction of the way down the chapter rather than a
    /// point, so it still lands in the right place when the window is a
    /// different size.
    ///
    /// This is written to disk but **not announced**: the place changes on
    /// every scroll, and telling the whole interface about it would redraw
    /// the library and the notes for nothing. The card shows the chapter,
    /// and that changes are announced by `markReading`.
    func setPosition(documentId: String, chapter: Int, scroll: Double) {
        // Chapter zero is the briefing, which every book opens on. Writing it
        // over a saved place would throw the reader's place away every time
        // they opened a book, so it is not a place and is not written.
        guard chapter > 0 else { return }
        let clamped = min(max(scroll, 0), 1)
        mutate { state in
            state.positions[documentId] = ReadingPosition(
                chapter: chapter, scroll: clamped, updatedAt: Date()
            )
            state.lastReadDocumentId = documentId
            state.lastReadChapter = chapter
        }
        save()
    }

    /// Forget where the reader was in a document.
    func clearPosition(documentId: String) {
        _ = mutate { $0.positions.removeValue(forKey: documentId) }
        save()
    }

    // MARK: Bulk read state

    /// Mark documents as read, or unread, all at once.
    ///
    /// Ticking every card one by one is a waste of a morning.
    func setRead(_ isRead: Bool, documentIds: [String]) {
        guard !documentIds.isEmpty else { return }
        mutate { state in
            for id in documentIds {
                if isRead {
                    state.read.insert(id)
                } else {
                    state.read.remove(id)
                }
            }
        }
        commit()
    }

    /// The documents that are not marked as read yet.
    func unreadDocuments(from documents: [LibraryDocument]) -> [LibraryDocument] {
        withState { state in
            documents.filter { !state.read.contains($0.id) }
        }
    }

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
    func addNote(documentId: String? = nil,
                 documentTitle: String = "",
                 body: String = "",
                 chapter: Int = 0) -> StudyNote {
        let now = Date()
        let note = StudyNote(
            id: UUID().uuidString,
            documentId: documentId ?? "",
            documentTitle: documentTitle,
            body: body,
            createdAt: now,
            updatedAt: now,
            chapter: chapter
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
        mutate { state in
            state.notes.removeAll { $0.id == id }
            // The note's place in the review schedule goes with it. Left
            // behind, it is a card for a note that no longer exists.
            state.reviews.removeValue(forKey: id)
        }
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

    // MARK: Review

    /// How long a note waits between reviews, in days.
    ///
    /// The first few come back quickly, because a note you have just written
    /// is fresh; after that they spread out, because a note you have
    /// remembered several times does not need asking every day.
    static let reviewIntervals: [Int] = [1, 3, 7, 16, 35]

    /// How long a forgotten note waits before it comes back.
    ///
    /// Ten minutes: long enough that you are not shown it again in the same
    /// breath, short enough that it comes back before you have closed the
    /// app.
    static let lapseInterval: TimeInterval = 10 * 60

    /// The notes that are due to be reviewed now, soonest first.
    func dueNotes(now: Date = Date()) -> [StudyNote] {
        let states = withState { $0.reviews }
        let notes = allNotes

        // A note nobody has reviewed is due straight away. Otherwise it is
        // due when its schedule says so.
        let due = notes.filter { note in
            guard let state = states[note.id] else { return true }
            return state.dueAt <= now
        }

        return due.sorted { left, right in
            let leftDue = states[left.id]?.dueAt ?? .distantPast
            let rightDue = states[right.id]?.dueAt ?? .distantPast
            if leftDue != rightDue { return leftDue < rightDue }
            return left.updatedAt < right.updatedAt
        }
    }

    /// The notes that are not due yet.
    func notesNotDue(now: Date = Date()) -> [StudyNote] {
        let states = withState { $0.reviews }
        return allNotes.filter { note in
            guard let state = states[note.id] else { return false }
            return state.dueAt > now
        }
    }

    func reviewState(for noteId: String) -> ReviewState? {
        withState { $0.reviews[noteId] }
    }

    /// Record the answer to a review card.
    ///
    /// Remembering it moves the note further out; forgetting it brings it
    /// back in ten minutes and starts the count again.
    func recordReview(noteId: String, remembered: Bool, now: Date = Date()) {
        mutate { state in
            let previous = state.reviews[noteId] ?? ReviewState()
            let repetitions = remembered ? previous.repetitions + 1 : 0
            let days = Self.reviewIntervals[min(repetitions, Self.reviewIntervals.count - 1)]
            let dueAt = remembered
                ? now.addingTimeInterval(TimeInterval(days) * 24 * 60 * 60)
                : now.addingTimeInterval(Self.lapseInterval)
            state.reviews[noteId] = ReviewState(
                repetitions: repetitions,
                dueAt: dueAt,
                lastReviewedAt: now
            )
        }
        commit()
    }

    /// How many notes are waiting to be reviewed.
    var dueCount: Int { dueNotes().count }
}
