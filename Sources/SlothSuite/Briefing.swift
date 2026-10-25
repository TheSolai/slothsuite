import Cocoa
import Foundation

// MARK: - Briefing

/// The synthesised briefing for one document.
///
/// SlothRead already produces this content; the native reader renders it
/// instead of making the user read it inside a web page.
struct Briefing: Equatable {
    var documentId: String
    var title: String
    var author: String
    var filename: String
    var status: String
    var thesis: String
    var executiveSummary: String
    var conclusions: [String]
    var keyPoints: [String]
    var chapters: [BriefingChapter]
    var standardReadingMinutes: Int
    var timeSavedMinutes: Int
    var totalWords: Int
    var createdAt: String

    var isComplete: Bool { status == "completed" }
    var totalTakeaways: Int { chapters.reduce(0) { $0 + $1.takeaways.count } }

    /// Plain text for searching, speaking and exporting.
    var plainText: String {
        var parts: [String] = [title, author, thesis, executiveSummary]
        parts.append(contentsOf: conclusions)
        parts.append(contentsOf: keyPoints)
        for chapter in chapters {
            parts.append(chapter.title)
            parts.append(contentsOf: chapter.takeaways)
            parts.append(contentsOf: chapter.keyTerms.map { "\($0.term): \($0.definition)" })
            parts.append(contentsOf: chapter.glossary.map { "\($0.term): \($0.definition)" })
            parts.append(contentsOf: chapter.tips)
            parts.append(contentsOf: chapter.hints)
        }
        return parts.joined(separator: "\n\n")
    }

    init?(json: [String: Any]) {
        guard let id = (json["doc_id"] as? String) ?? (json["id"] as? String) else { return nil }

        let synthesis = json["synthesis"] as? [String: Any] ?? [:]

        documentId = id
        title = (json["title"] as? String) ?? (json["filename"] as? String) ?? "Untitled"
        author = (json["author"] as? String) ?? ""
        filename = (json["filename"] as? String) ?? ""
        status = (json["status"] as? String) ?? "unknown"
        thesis = (synthesis["thesis"] as? String) ?? ""
        executiveSummary = (synthesis["executive_summary"] as? String) ?? ""
        conclusions = (synthesis["primary_conclusions"] as? [String]) ?? []
        keyPoints = (synthesis["key_points"] as? [String]) ?? []
        standardReadingMinutes = (synthesis["standard_reading_time_minutes"] as? Int) ?? 0
        timeSavedMinutes = (synthesis["time_saved_minutes"] as? Int) ?? 0
        totalWords = (json["total_words"] as? Int) ?? 0
        createdAt = (json["created_at"] as? String) ?? ""

        chapters = []
        for raw in (json["chapters"] as? [[String: Any]]) ?? [] {
            let glossary = (raw["glossary"] as? [[String: Any]] ?? []).map {
                BriefingGlossary(
                    term: ($0["term"] as? String) ?? "",
                    definition: ($0["definition"] as? String) ?? ""
                )
            }
            let keyTerms = (raw["key_terms"] as? [[String: Any]] ?? []).map {
                BriefingGlossary(
                    term: ($0["term"] as? String) ?? "",
                    definition: ($0["definition"] as? String) ?? ""
                )
            }
            chapters.append(BriefingChapter(
                title: (raw["title"] as? String) ?? "Chapter",
                pageRange: (raw["page_range"] as? String) ?? "",
                wordCount: (raw["word_count"] as? Int) ?? 0,
                takeaways: (raw["takeaways"] as? [String]) ?? [],
                keyTerms: keyTerms,
                keywords: (raw["keywords"] as? [String]) ?? [],
                glossary: glossary,
                tips: (raw["tips"] as? [String]) ?? [],
                hints: (raw["hints"] as? [String]) ?? [],
                audioScript: (raw["audio_script"] as? String) ?? ""
            ))
        }
    }
}

/// One chapter of a briefing.
struct BriefingChapter: Equatable {
    var title: String
    var pageRange: String
    var wordCount: Int
    var takeaways: [String]
    /// The three ideas the chapter is actually about.
    var keyTerms: [BriefingGlossary]
    /// Short tags naming what the chapter covers.
    var keywords: [String]
    var glossary: [BriefingGlossary]
    /// What the reader could do with this chapter.
    var tips: [String]
    /// What is worth noticing in it.
    var hints: [String]
    var audioScript: String

    /// What the Mac voice should say for this chapter.
    var spokenText: String {
        var parts: [String] = [title]
        if !takeaways.isEmpty {
            parts.append("Three high-impact takeaways.")
            parts.append(contentsOf: takeaways.enumerated().map { "\($0.offset + 1). \($0.element)" })
        }
        return parts.joined(separator: ". ")
    }
}

/// A term and its definition.
struct BriefingGlossary: Equatable {
    var term: String
    var definition: String
}

// MARK: - Fetching

/// Loads briefings from the app's backend.
final class BriefingStore {
    static let shared = BriefingStore()

    private(set) var briefings: [String: Briefing] = [:]
    private var inFlight: Set<String> = []

    /// Fired when a briefing finishes loading.
    var onChange: (() -> Void)?

    private init() {}

    /// The briefing for a document, if it has been loaded.
    func briefing(documentId: String) -> Briefing? {
        briefings[documentId]
    }

    /// Load a briefing. Safe to call repeatedly for the same document.
    func load(documentId: String, spec: AppSpec?, completion: ((Briefing?) -> Void)? = nil) {
        guard !inFlight.contains(documentId) else { return }
        guard let base = spec?.apiBase else {
            completion?(nil)
            return
        }

        inFlight.insert(documentId)

        var request = URLRequest(url: base.appendingPathComponent("/api/documents/\(documentId)"))
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight.remove(documentId)

                if let error {
                    Log.shared.write("briefing load failed for \(documentId): \(error.localizedDescription)")
                    completion?(nil)
                    return
                }

                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      let data,
                      let json = JSONTools.dictionary(from: data),
                      let briefing = Briefing(json: json) else {
                    completion?(nil)
                    return
                }

                self.briefings[documentId] = briefing
                self.onChange?()
                completion?(briefing)
            }
        }.resume()
    }
}
