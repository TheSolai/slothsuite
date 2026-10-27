import Cocoa
import Foundation

// MARK: - The book as it was

/// A chapter of the book's own text.
///
/// The briefing is a distillation of a book; this is the book. A note
/// taken here is taken against a passage, not against a summary of one.
struct OriginalChapter {
    let id: Int
    let title: String
    let text: String
    let wordCount: Int

    /// The text, in paragraphs.
    ///
    /// An EPUB keeps its paragraphs apart with tabs, and the text comes
    /// out of the file as one long string with tabs in it. A reader
    /// cannot read a wall of tab-separated words, so the tabs become
    /// paragraph breaks and the non-breaking spaces become spaces.
    var paragraphs: [String] {
        let cleaned = text
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(of: "\r", with: "\n")
        var result: [String] = []
        for piece in cleaned.components(separatedBy: CharacterSet(charactersIn: "\t\n")) {
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.append(trimmed) }
        }
        return result
    }

    /// The text, in paragraphs, without the heading the page already shows.
    ///
    /// A book's file usually opens a chapter with its own heading — "I THE
    /// EXPERIMENT", "Preface", "Introduction". The page carries a title
    /// too, and the heading repeated underneath it is noise. The heading
    /// is only dropped when it says what the title already says; a book
    /// that opens differently keeps its own first line, because that is
    /// the book's own structure rather than a copy of the title.
    ///
    /// A heading may be more than one line — "I" and "THE EXPERIMENT" are
    /// one heading in two parts — so the lines are gathered until they
    /// agree with the title or stop agreeing with it.
    func paragraphs(withoutHeadings titles: [String]) -> [String] {
        let all = paragraphs
        guard !all.isEmpty else { return all }

        for title in titles {
            let wanted = Self.words(in: title)
            guard !wanted.isEmpty else { continue }

            // The words gathered so far, and how many paragraphs they
            // came from. The two are not the same: a heading of three
            // words may be two paragraphs of one word each.
            var gathered: [String] = []
            var taken = 0
            for paragraph in all {
                let words = Self.words(in: paragraph)
                guard !words.isEmpty else { break }
                let combined = gathered + words
                // Stop as soon as the heading stops agreeing with the title.
                guard wanted.starts(with: combined) else { break }
                gathered = combined
                taken += 1
                if combined == wanted {
                    let rest = Array(all.dropFirst(taken))
                    // A chapter that is nothing but its heading keeps the
                    // heading; an empty page helps nobody.
                    return rest.isEmpty ? all : rest
                }
            }
        }
        return all
    }

    /// The words of a string: lowercased, with the punctuation taken out.
    private static func words(in text: String) -> [String] {
        let lowered = text.lowercased().replacingOccurrences(of: "\u{00a0}", with: " ")
        let cleaned = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == " " ? Character(scalar) : " "
        }
        return String(cleaned).split(separator: " ").map(String.init)
    }
}

/// The document's original file: the book the reader brought in.
struct OriginalDocument {
    let available: Bool
    let documentId: String
    let filename: String
    let title: String
    let author: String
    let fileType: String
    let totalWords: Int
    let chapters: [OriginalChapter]

    /// Why the original is not there, when it is not.
    let reason: String

    init(json: [String: Any]) {
        documentId = json["doc_id"] as? String ?? ""
        filename = json["filename"] as? String ?? ""
        title = json["title"] as? String ?? ""
        author = json["author"] as? String ?? ""
        fileType = json["file_type"] as? String ?? ""
        totalWords = json["total_words"] as? Int ?? 0
        available = (json["available"] as? Bool) ?? false
        reason = json["reason"] as? String ?? ""

        var parsed: [OriginalChapter] = []
        for raw in (json["chapters"] as? [[String: Any]]) ?? [] {
            let text = raw["text"] as? String ?? ""
            parsed.append(OriginalChapter(
                id: raw["chapter_id"] as? Int ?? (parsed.count + 1),
                title: raw["title"] as? String ?? "",
                text: text,
                wordCount: raw["word_count"] as? Int ?? text.split(whereSeparator: { $0.isWhitespace }).count
            ))
        }
        chapters = parsed
    }

    /// The chapter with this number, if there is one.
    func chapter(_ id: Int) -> OriginalChapter? {
        chapters.first { $0.id == id }
    }
}

// MARK: - Fetching it

/// The originals of the books in the library.
///
/// The original is kept beside the synthesis, because the synthesis is a
/// distillation and the book's own words are not in it. This is how the
/// reader gets at those words.
final class OriginalStore {
    static let shared = OriginalStore()

    private(set) var originals: [String: OriginalDocument] = [:]

    /// The documents being fetched right now.
    private var inFlight: Set<String> = []

    /// The callers waiting on a fetch that is already running.
    ///
    /// A second caller for a document that is already being fetched still
    /// wants an answer. Without this the second caller is left waiting for
    /// something that never arrives.
    private var waiting: [String: [(OriginalDocument?) -> Void]] = [:]

    /// Fired when an original finishes loading.
    var onChange: (() -> Void)?

    private init() {}

    /// The original of a document, if it has been loaded.
    func original(documentId: String) -> OriginalDocument? {
        originals[documentId]
    }

    /// Load the original of a document. Safe to call repeatedly.
    func load(documentId: String, spec: AppSpec?, completion: ((OriginalDocument?) -> Void)? = nil) {
        guard let base = spec?.apiBase else {
            completion?(nil)
            return
        }

        if inFlight.contains(documentId) {
            if let completion {
                waiting[documentId, default: []].append(completion)
            }
            return
        }

        inFlight.insert(documentId)

        var request = URLRequest(url: base.appendingPathComponent("/api/documents/\(documentId)/original"))
        // Parsing a book takes a moment, so the wait is longer than for
        // the briefing.
        request.timeoutInterval = 60

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight.remove(documentId)

                if let error {
                    Log.shared.write("original load failed for \(documentId): \(error.localizedDescription)")
                    self.answer(documentId: documentId, document: nil, completion: completion)
                    return
                }

                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      let data,
                      let json = JSONTools.dictionary(from: data) else {
                    self.answer(documentId: documentId, document: nil, completion: completion)
                    return
                }

                let document = OriginalDocument(json: json)
                self.originals[documentId] = document
                self.answer(documentId: documentId, document: document, completion: completion)
                self.onChange?()
            }
        }.resume()
    }

    /// Answer everybody who was waiting for this document.
    private func answer(documentId: String,
                        document: OriginalDocument?,
                        completion: ((OriginalDocument?) -> Void)?) {
        completion?(document)
        let waiting = self.waiting[documentId] ?? []
        self.waiting[documentId] = nil
        for waiter in waiting { waiter(document) }
    }

    /// Give a document its original file back.
    ///
    /// The original was deleted for a while, so books added before it was
    /// kept have no file. This is how the file is given back: the same
    /// file, attached to the same document, without paying for another
    /// synthesis.
    func attach(documentId: String,
                spec: AppSpec?,
                fileURL: URL,
                completion: @escaping (Bool) -> Void) {
        guard let base = spec?.apiBase else {
            completion(false)
            return
        }

        let boundary = "SlothSuite-\(UUID().uuidString)"
        var request = URLRequest(url: base.appendingPathComponent("/api/documents/\(documentId)/original"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120

        let body = NSMutableData()
        let filename = fileURL.lastPathComponent
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        if let data = try? Data(contentsOf: fileURL) { body.append(data) }
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body as Data
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error {
                    Log.shared.write("could not attach the original: \(error.localizedDescription)")
                    completion(false)
                    return
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(code) else {
                    let detail = (data.flatMap { JSONTools.dictionary(from: $0)?["detail"] as? String }) ?? "HTTP \(code)"
                    Log.shared.write("could not attach the original: \(detail)")
                    completion(false)
                    return
                }
                Log.shared.write("attached the original for \(documentId)")
                // The document it was attached to has changed, so the old
                // one is thrown away rather than shown.
                self?.originals[documentId] = nil
                completion(true)
            }
        }.resume()
    }
}
