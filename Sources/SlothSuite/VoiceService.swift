import Cocoa
import Foundation

/// The voice the suite reads the books aloud with.
///
/// There are two kinds, and they are both local: the Mac's own speech
/// synthesiser, which has always been here, and **Phonon** — Gradium's
/// small text-to-speech model, which Ollama runs on this machine and which
/// Ollama speaks through an OpenAI-compatible endpoint.
///
/// The Phonon voices are the reason there is a choice at all. The Mac has
/// one voice; Phonon has thirty-eight, from plain narrators to a Fairy
/// Godmother and a Captain Silas Blackwater.
enum ReadingVoice: Equatable {
    /// The Mac's own voice, through the bundled helper.
    case mac
    /// A Phonon voice from Ollama, by name.
    case phonon(String)

    /// The name shown in the interface.
    var displayName: String {
        switch self {
        case .mac:
            return "Mac voice"
        case .phonon(let name):
            return "Phonon · \(name)"
        }
    }

    /// The voice in a form that can be written down and read back.
    var storedValue: String {
        switch self {
        case .mac:
            return "mac"
        case .phonon(let name):
            return "phonon:\(name)"
        }
    }

    /// The voice a stored name means.
    static func fromStored(_ raw: String) -> ReadingVoice? {
        if raw == "mac" { return .mac }
        guard raw.hasPrefix("phonon:") else { return nil }
        let name = String(raw.dropFirst("phonon:".count))
        guard !name.isEmpty else { return nil }
        return .phonon(name)
    }
}

/// The voice the suite reads with, and the work of turning text into audio.
final class VoiceService {
    static let shared = VoiceService()

    /// Posted when the voice changes, so the interface can redraw.
    static let voiceChanged = Notification.Name("SlothSuite.readingVoiceChanged")

    /// The voice Ollama is asked for by default.
    ///
    /// "default" is the checkpoint's own voice — the one Gradium shipped
    /// with it — so it is the safest thing to read a whole book in.
    static let defaultPhononVoice = "default"

    private static let defaultsKey = "SlothSuite.readingVoice"

    /// The voice in use.
    private(set) var voice: ReadingVoice

    /// The Phonon voices Ollama has, if it is running.
    private(set) var phononVoices: [String] = []

    /// Whether the suite may put a panel in front of the reader.
    ///
    /// The self-test runs with nobody in front of it, and a panel there
    /// would hang the run rather than warn anybody.
    var allowsAlerts = true

    /// Whether the reader has already been told that Phonon is not there.
    ///
    /// The notice is worth giving once: after that the suite falls back to
    /// the Mac's voice quietly, because a book that stops being read
    /// altogether is worse than a book read in the wrong voice.
    private var hasWarnedAboutPhonon = false

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? ""
        voice = ReadingVoice.fromStored(raw) ?? .phonon(Self.defaultPhononVoice)
    }

    // MARK: - Choosing

    /// Use a different voice.
    func choose(_ new: ReadingVoice) {
        guard new != voice else { return }
        voice = new
        UserDefaults.standard.set(new.storedValue, forKey: Self.defaultsKey)
        Log.shared.write("reading voice is now \(new.displayName)")
        NotificationCenter.default.post(name: Self.voiceChanged, object: self)
    }

    // MARK: - The voices Ollama has

    /// Ask Ollama what voices it has.
    ///
    /// The list is fetched in the background and kept: the voices of a
    /// model do not change while the app is open, and the menu that shows
    /// them has to be ready the moment it is opened.
    func refreshVoices(completion: (([String]) -> Void)? = nil) {
        PhononService.shared.voices { [weak self] names in
            DispatchQueue.main.async {
                guard let self else { return }
                if !names.isEmpty { self.phononVoices = names }
                completion?(self.phononVoices)
            }
        }
    }

    // MARK: - Making the audio

    /// How many pieces of audio a text needs.
    ///
    /// The Mac's voice speaks a whole text in one go. Phonon cannot: it
    /// will not take more than a few thousand characters at a time, so a
    /// long chapter is several pieces, and the pieces are read one after
    /// another.
    func pieceCount(for text: String) -> Int {
        switch voice {
        case .mac:
            return 1
        case .phonon:
            return SpeechChunker.pieces(of: text).count
        }
    }

    /// Make one piece of the audio for a text.
    func makePiece(of text: String,
                   at index: Int,
                   completion: @escaping (Result<Data, Error>) -> Void) {
        switch voice {
        case .mac:
            guard index == 0 else {
                completion(.success(Data()))
                return
            }
            MacServices.shared.speak(text: text) { result in
                completion(result)
            }

        case .phonon(let name):
            let pieces = SpeechChunker.pieces(of: text)
            guard index < pieces.count else {
                completion(.success(Data()))
                return
            }
            let chunk = pieces[index]
            PhononService.shared.speak(text: chunk, voice: name) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let data):
                    completion(.success(data))
                case .failure(let error):
                    // Ollama is not answering. The Mac's voice reads this
                    // piece instead, so the book keeps being read.
                    Log.shared.write("phonon could not speak: \(error.localizedDescription)")
                    self.warnAboutPhonon(error)
                    MacServices.shared.speak(text: chunk) { fallback in
                        completion(fallback)
                    }
                }
            }
        }
    }

    /// Tell the reader once that their Phonon voice is not working.
    private func warnAboutPhonon(_ error: Error) {
        guard allowsAlerts else { return }
        guard !hasWarnedAboutPhonon else { return }
        hasWarnedAboutPhonon = true
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "The Phonon voice is not answering"
            alert.informativeText = "Ollama is not running, or it is not answering on its local address. "
                + "The book is being read with the Mac's own voice instead. "
                + "Start Ollama and choose a Phonon voice again to use it."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}

/// A small panel for choosing a voice.
///
/// The reader's **Listen** menu is the usual way in. This is for the
/// places a menu cannot be opened — the command palette, for one.
enum VoicePicker {

    /// Ask which voice the books should be read with.
    static func present() {
        let current = VoiceService.shared.voice
        let voices = VoiceService.shared.phononVoices

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Read the books with"

        if voices.isEmpty {
            // Ollama is not answering, so there is nothing to choose
            // between but the Mac's own voice.
            alert.informativeText = "Ollama is not answering, so the Phonon voices are not available. "
                + "Start Ollama to use them."
            alert.addButton(withTitle: "Use the Mac voice")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                VoiceService.shared.choose(.mac)
            }
            return
        }

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
        popup.addItem(withTitle: ReadingVoice.mac.displayName)
        for name in voices {
            popup.addItem(withTitle: ReadingVoice.phonon(name).displayName)
        }
        popup.selectItem(at: Self.index(of: current, voices: voices))
        alert.accessoryView = popup
        alert.informativeText = "Ollama's Phonon voices run on this Mac. "
            + "The Mac's own voice is here too."
        alert.addButton(withTitle: "Use")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let index = popup.indexOfSelectedItem
        if index <= 0 {
            VoiceService.shared.choose(.mac)
        } else if index - 1 < voices.count {
            VoiceService.shared.choose(.phonon(voices[index - 1]))
        }
    }

    /// Where the voice in use sits in the list.
    private static func index(of voice: ReadingVoice, voices: [String]) -> Int {
        switch voice {
        case .mac:
            return 0
        case .phonon(let name):
            guard let position = voices.firstIndex(of: name) else { return 0 }
            return position + 1
        }
    }
}

/// Ollama's speech endpoint.
///
/// The address is Ollama's own, on this machine, and it is written down
/// here rather than taken from anywhere the user can change it: nothing
/// that arrives from a document or a web page can point the suite at
/// another address.
final class PhononService {
    static let shared = PhononService()

    /// Ollama's local address.
    let baseURL = URL(string: "http://127.0.0.1:11434")!

    /// The model the voices belong to. The bare name follows Ollama's own
    /// default tag, so the voice that is used is the one `ollama show
    /// phonon` describes.
    let model = "phonon"

    private init() {}

    /// The voices the model has.
    func voices(completion: @escaping ([String]) -> Void) {
        var request = URLRequest(url: baseURL.appendingPathComponent("/api/show"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model])
        request.timeoutInterval = 5

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard error == nil,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data = data,
                  let json = JSONTools.dictionary(from: data),
                  let names = json["voices"] as? [String], !names.isEmpty else {
                completion([])
                return
            }
            completion(names)
        }.resume()
    }

    /// Speak a piece of text.
    func speak(text: String,
               voice: String,
               completion: @escaping (Result<Data, Error>) -> Void) {
        var request = URLRequest(url: baseURL.appendingPathComponent("/v1/audio/speech"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "input": text,
            "voice": voice,
            "response_format": "wav"
        ])
        // A full piece is a few thousand characters, which takes a few
        // seconds to make on a Mac with a local model.
        request.timeoutInterval = 180

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data = data, !data.isEmpty else {
                completion(.failure(PhononError.badResponse))
                return
            }
            completion(.success(data))
        }.resume()
    }
}

enum PhononError: LocalizedError {
    case badResponse

    var errorDescription: String? {
        switch self {
        case .badResponse: return "Ollama did not return any audio."
        }
    }
}

/// Splits a text into the pieces Ollama will accept.
///
/// Ollama refuses more than a few thousand characters in one request, and
/// a chapter of a book is a good deal longer than that. The split is made
/// where a person would make it: at a paragraph, then at a sentence, then
/// at a space. A word is never cut in half, because a word cut in half is
/// not a word and it does not sound like one either.
enum SpeechChunker {

    /// The most characters Ollama will take in one request.
    static let limit = 4096

    /// Split a text into pieces, each no longer than the limit.
    static func pieces(of text: String, limit: Int = SpeechChunker.limit) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.count > limit else { return [trimmed] }

        var pieces: [String] = []
        var rest = Substring(trimmed)

        while rest.count > limit {
            let window = rest.prefix(limit)
            let cut = bestBreak(in: window)
            let piece = rest[..<cut.end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { pieces.append(String(piece)) }
            rest = rest[cut.next...].drop(while: { $0 == " " || $0 == "\n" || $0 == "\t" })
        }

        let last = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty { pieces.append(last) }
        return pieces
    }

    /// Where to break a window: a paragraph, then a sentence, then a space.
    ///
    /// The *last* of each kind is taken, so the pieces are as long as they
    /// can be without going over the limit. The end of the piece and the
    /// start of the next one are both returned, because a sentence break
    /// keeps its full stop and a paragraph break does not.
    private static func bestBreak(in window: Substring) -> (end: Substring.Index, next: Substring.Index) {
        var paragraph: Substring.Index?
        var sentence: Substring.Index?
        var space: Substring.Index?

        var index = window.startIndex
        while index < window.endIndex {
            let character = window[index]
            if character == "\n" {
                let after = window.index(after: index)
                if after < window.endIndex, window[after] == "\n" {
                    paragraph = index
                }
            } else if character == "." || character == "!" || character == "?" {
                sentence = index
            } else if character == " " {
                space = index
            }
            index = window.index(after: index)
        }

        if let paragraph {
            let after = window.index(after: paragraph)
            return (paragraph, after)
        }
        if let sentence {
            let after = window.index(after: sentence)
            return (after, after)
        }
        if let space {
            return (space, space)
        }

        // Nothing to break on: cut at the limit, in the middle of a word
        // if that is what it comes to.
        let end = window.index(window.startIndex, offsetBy: window.count)
        return (end, end)
    }
}
