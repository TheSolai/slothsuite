import Cocoa
import Foundation

// MARK: - Modules

/// A functional area of the suite.
///
/// The suite is meant to grow into a complete learning toolkit — library,
/// reader, notes, spaced repetition. Each area is a module, and the sidebar
/// is generated from this list, so adding one is a single line here plus a
/// view.
enum ModuleKind {
    /// The native document library.
    case library
    /// The native briefing reader.
    case reader
    /// The native notes module.
    case notes
    /// The review desk — spaced repetition over the notes.
    case review
    /// The wrapped web app — the synthesis engine.
    case app
    /// Reserved for a module that does not exist yet.
    case planned
}

struct SuiteModule: Identifiable {
    let id: String
    let title: String
    /// An SF Symbol name.
    let symbol: String
    let kind: ModuleKind
    var isAvailable: Bool { kind != .planned }
}

enum SuiteModules {
    /// The navigation order.
    ///
    /// The learning areas come first, because that is what the suite is for.
    /// The wrapped app is the engine that produces briefings; it is a tool,
    /// not a destination, so it sits at the bottom.
    static let all: [SuiteModule] = [
        SuiteModule(id: "library", title: "Library", symbol: "books.vertical.fill", kind: .library),
        SuiteModule(id: "reader", title: "Reader", symbol: "text.book.closed.fill", kind: .reader),
        SuiteModule(id: "notes", title: "Notes", symbol: "note.text", kind: .notes),
        SuiteModule(id: "review", title: "Review", symbol: "brain.head.profile", kind: .review),
        SuiteModule(id: "app", title: "App", symbol: "macwindow.on.rectangle", kind: .app)
    ]

    static func module(id: String) -> SuiteModule? {
        all.first { $0.id == id }
    }
}

// MARK: - Library model

/// One document in the library.
struct LibraryDocument: Identifiable {
    let id: String
    let title: String
    let author: String
    let filename: String
    let fileType: String
    let status: String
    let chapters: Int
    let words: Int
    let minutesSaved: Int
    let createdAt: String

    var isReady: Bool { status == "completed" }
    var isFailed: Bool { status == "failed" }
    var isBusy: Bool { status == "processing" || status == "queued" }

    /// A short label for the file type, e.g. "PDF" or "EPUB".
    var typeLabel: String {
        fileType.isEmpty ? "FILE" : fileType.uppercased()
    }

    /// "8 min saved", or nil when there is nothing to show.
    var savedLabel: String? {
        minutesSaved > 0 ? "\(minutesSaved) min saved" : nil
    }

    /// The date, shortened for a card.
    var dateLabel: String {
        guard !createdAt.isEmpty else { return "" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: createdAt) else { return createdAt.prefix(10).description }
        let out = DateFormatter()
        out.dateStyle = .medium
        out.timeStyle = .none
        return out.string(from: date)
    }

    init?(json: [String: Any]) {
        guard let id = json["doc_id"] as? String else { return nil }
        self.id = id
        self.title = (json["title"] as? String) ?? (json["filename"] as? String) ?? "Untitled"
        self.author = (json["author"] as? String) ?? ""
        self.filename = (json["filename"] as? String) ?? ""
        self.fileType = (json["file_type"] as? String) ?? ""
        self.status = (json["status"] as? String) ?? "unknown"
        self.chapters = (json["total_chapters"] as? Int) ?? 0
        self.words = (json["total_words"] as? Int) ?? 0
        self.minutesSaved = (json["time_saved_minutes"] as? Int) ?? 0
        self.createdAt = (json["created_at"] as? String) ?? ""
    }
}

// MARK: - Library store

/// How the library list is filtered.
enum LibraryFilter: String, CaseIterable {
    case all = "All"
    case favourites = "Favourites"
    case unread = "Unread"
    case ready = "Ready"

    var title: String { rawValue }

    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .favourites: return "star"
        case .unread: return "circle"
        case .ready: return "checkmark.circle"
        }
    }
}

/// How the library list is sorted.
enum LibrarySort: String, CaseIterable {
    /// Newest first. The default, because a new document is usually why
    /// you came here.
    case recent = "Recent"
    /// By title, A to Z.
    case title = "Title"
    /// By author, A to Z.
    case author = "Author"
    /// The longest documents first — the ones worth the time.
    case longest = "Longest"

    var title: String { rawValue }

    var symbol: String {
        switch self {
        case .recent: return "clock"
        case .title: return "textformat.abc"
        case .author: return "person"
        case .longest: return "arrow.up.right.square"
        }
    }
}

/// Fetches the library and tells whoever is watching when it changes.
final class LibraryStore {
    static let shared = LibraryStore()

    private(set) var documents: [LibraryDocument] = []
    private(set) var query = ""
    private(set) var filter: LibraryFilter = .all
    private(set) var sort: LibrarySort = .recent
    var onChange: (([LibraryDocument]) -> Void)?

    private var timer: Timer?

    private init() {}

    /// The filtered list, honouring the search query and the filter chips.
    var filtered: [LibraryDocument] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let learning = LearningStore.shared

        var result = documents.filter { document in
            if !needle.isEmpty {
                let haystack = "\(document.title) \(document.author) \(document.filename)".lowercased()
                guard haystack.contains(needle) else { return false }
            }

            switch filter {
            case .all: return true
            case .favourites: return learning.isFavourite(documentId: document.id)
            case .unread: return !learning.isRead(documentId: document.id)
            case .ready: return document.isReady
            }
        }

        // Favourites float to the top — but only when the order has not been
        // asked for. Sorting by title and then putting favourites on top
        // would not be the order that was asked for.
        result.sort { left, right in
            if sort == .recent {
                let leftFavourite = learning.isFavourite(documentId: left.id)
                let rightFavourite = learning.isFavourite(documentId: right.id)
                if leftFavourite != rightFavourite { return leftFavourite }
                return left.createdAt > right.createdAt
            }

            switch sort {
            case .recent:
                return left.createdAt > right.createdAt
            case .title:
                return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
            case .author:
                // A document with no author is sorted by its title, rather
                // than by an empty string that would put it first.
                let leftName = left.author.isEmpty ? left.title : left.author
                let rightName = right.author.isEmpty ? right.title : right.author
                if leftName == rightName {
                    return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
                }
                return leftName.localizedCaseInsensitiveCompare(rightName) == .orderedAscending
            case .longest:
                if left.words == right.words {
                    return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
                }
                return left.words > right.words
            }
        }

        return result
    }

    func setQuery(_ text: String) {
        query = text
        onChange?(filtered)
    }

    func setFilter(_ newFilter: LibraryFilter) {
        filter = newFilter
        onChange?(filtered)
    }

    func setSort(_ newSort: LibrarySort) {
        sort = newSort
        onChange?(filtered)
    }

    /// How many documents each filter would show.
    func count(for candidate: LibraryFilter) -> Int {
        let learning = LearningStore.shared
        switch candidate {
        case .all: return documents.count
        case .favourites: return documents.filter { learning.isFavourite(documentId: $0.id) }.count
        case .unread: return documents.filter { !learning.isRead(documentId: $0.id) }.count
        case .ready: return documents.filter { $0.isReady }.count
        }
    }

    /// Refresh from the backend.
    func refresh(spec: AppSpec?) {
        guard let spec, let base = spec.apiBase, let path = spec.libraryPath else {
            documents = []
            onChange?(filtered)
            return
        }

        var request = URLRequest(url: base.appendingPathComponent(path))
        request.timeoutInterval = 5

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }

                if let error {
                    Log.shared.write("library fetch failed: \(error.localizedDescription)")
                    return
                }

                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data = data,
                      let json = JSONTools.dictionary(from: data),
                      let raw = json["documents"] as? [[String: Any]] else {
                    return
                }

                let parsed = raw.compactMap { LibraryDocument(json: $0) }
                if parsed.map(\.id) != self.documents.map(\.id) {
                    self.documents = parsed
                    self.onChange?(self.filtered)
                } else {
                    // Same documents, but their contents may have changed.
                    self.documents = parsed
                    self.onChange?(self.filtered)
                }
            }
        }.resume()
    }

    /// Start polling for changes.
    func startPolling(spec: AppSpec?, interval: TimeInterval = 15) {
        stopPolling()
        refresh(spec: spec)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh(spec: spec)
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func document(id: String) -> LibraryDocument? {
        documents.first { $0.id == id }
    }
}
