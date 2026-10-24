import Cocoa
import Foundation
import WebKit

/// Headless verification of the suite.
///
/// The original `--selftest` logged what it observed and then always called
/// `exit(0)`, so it could never fail — a broken build would still report
/// success. This runner turns every observation into an assertion and exits
/// non-zero when something is wrong, which makes it usable as a build gate.
///
/// The whole run is callback-driven. Nothing here spins the run loop waiting
/// for a value: a page that never answers must not be able to freeze the
/// test, and a modal dialog must not be able to block it either.
final class SelfTestRunner {
    private let controller: SuiteController
    private let log = Log.shared
    private var failures = 0
    private var checks = 0

    /// The documents that were in the library before the test uploaded
    /// anything, so the test can take its own litter away again.
    private var libraryIdsBeforeUpload: Set<String> = []

    init(controller: SuiteController) {
        self.controller = controller
    }

    // MARK: - Assertion helpers

    private func check(_ name: String, _ passed: Bool, _ detail: String) {
        checks += 1
        if !passed { failures += 1 }
        let mark = passed ? "PASS" : "FAIL"
        // Asynchronous: the serial queue preserves ordering, and the final
        // summary write flushes everything before the process exits.
        log.write("SELFTEST \(mark) \(name) — \(detail)")
    }

    private func finish() {
        log.writeSync("SELFTEST end — \(checks - failures)/\(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Run

    func begin() {
        log.mirrorToStderr(true)
        log.writeSync("SELFTEST begin")

        // 1. Configuration
        let config = controller.configForTest
        check("config.apps", !config.apps.isEmpty, "\(config.apps.count) apps configured")
        check("config.services", !config.services.isEmpty, "\(config.services.count) services configured")

        // 2. The stack script must exist and be readable.
        let scriptURL = controller.stackForTest.scriptURL
        let scriptReadable = FileManager.default.isReadableFile(atPath: scriptURL.path)
        check("stack.script", scriptReadable, scriptURL.path)

        // 3. Every service must be listening.
        for service in config.services {
            let open = service.ports.allSatisfy { StackManager.isPortOpen($0) }
            check("stack.ports.\(service.id)", open, "ports \(service.ports)")
        }

        // 4. Every health endpoint must answer.
        for spec in config.apps {
            guard let (data, response) = Self.fetch(spec.healthURL) else {
                check("health.\(spec.id)", false, "no response from \(spec.healthURL)")
                continue
            }
            let status = HealthMonitor.parse(data: data, response: response, error: nil)
            check("health.\(spec.id)", status.ok, status.detail)
        }

        // 5. The active webview must actually be pointing somewhere.
        let activeID = controller.currentSpecForTest.id
        let webView = controller.webViewForTest(activeID)
        check("webview.attached", webView != nil, activeID)

        // Show the app module and wait for the page to actually be ready,
        // rather than guessing how long it takes to mount.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.continueRun()
        }
    }

    private func continueRun() {
        // The webview lives in the App module; make sure it is the one
        // on screen before probing it.
        controller.showModuleForTest("app")
        waitForPageReady(attempt: 0)
    }

    /// Wait until the page is actually ready to take commands.
    ///
    /// The wrapped app is a React page, and the navigation finishing is not
    /// the same as the app having mounted and registered its bridge handler.
    /// A fixed sleep was a race — the redesign widened it, because the page
    /// now loads when the App module is first shown rather than at launch.
    ///
    /// So the gate waits for the two things it actually needs: a title, and
    /// a bridge that answers.
    private func waitForPageReady(attempt: Int) {
        let activeID = controller.currentSpecForTest.id
        let webView = controller.webViewForTest(activeID)

        guard attempt < 60 else {
            check("page.ready", false, "the page never became ready")
            continueAfterReady()
            return
        }

        guard !(webView?.title ?? "").isEmpty else {
            retryReady(after: 0.5, attempt: attempt)
            return
        }

        guard let bridge = controller.bridgeForTest(activeID), let webView else {
            continueAfterReady()
            return
        }

        bridge.perform("status", in: webView) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.check("page.ready", true, webView.title ?? "ready")
                self.continueAfterReady()
            case .failure, .unsupported:
                self.retryReady(after: 0.5, attempt: attempt)
            }
        }
    }

    private func retryReady(after delay: TimeInterval, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.waitForPageReady(attempt: attempt + 1)
        }
    }

    /// Everything that needed a live page.
    private func continueAfterReady() {
        let activeID = controller.currentSpecForTest.id
        let webView = controller.webViewForTest(activeID)

        check("webview.url", webView?.url?.absoluteString != nil,
              webView?.url?.absoluteString ?? "no url")
        check("webview.title", !(webView?.title ?? "").isEmpty,
              webView?.title ?? "untitled")

        // 6. The bridge must work — this is the contract that replaced DOM
        //    scraping, so a silent failure here matters.
        guard let bridge = controller.bridgeForTest(activeID), let webView else {
            check("bridge.status", false, "no bridge")
            afterBridge()
            return
        }

        bridge.perform("status", in: webView) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                self.check("bridge.status", true, String(describing: value).trimmed(to: 120))
            case .failure(let message):
                self.check("bridge.status", false, message)
            case .unsupported(let message):
                self.check("bridge.status", false, message)
            }
            self.afterBridge()
        }
    }

    private func afterBridge() {
        // 7. The library endpoint must answer.
        if let spec = controller.specsForTest.first(where: { $0.supportsLibrary }),
           let base = spec.apiBase, let path = spec.libraryPath {
            let url = base.appendingPathComponent(path)
            if let (data, response) = Self.fetch(url) {
                let http = response as? HTTPURLResponse
                let json = JSONTools.dictionary(from: data)
                let documents = json?["documents"] as? [[String: Any]]
                check("library.documents",
                      http?.statusCode == 200 && documents != nil,
                      "HTTP \(http?.statusCode ?? 0), \(documents?.count ?? -1) documents")

                // Remember what was there, so the upload test can remove the
                // document it creates.
                libraryIdsBeforeUpload = Set(
                    (documents ?? []).compactMap { $0["doc_id"] as? String }
                )
            } else {
                check("library.documents", false, "no response from \(url)")
            }
        }

        // 8. The native modules must switch cleanly, and the suite's own
        //    learning store must survive a round trip.
        checkLearningModules()
        checkBriefing()

        // 9. The web-tools endpoints must exist. A 404 means the backend has
        //    no web access wired up; a 502 means it tried and the network
        //    said no, which still proves the endpoint is wired.
        for spec in controller.specsForTest {
            guard let base = spec.apiBase else { continue }
            var components = URLComponents(url: base.appendingPathComponent("/api/web/search"),
                                          resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "q", value: "local language model")]
            guard let url = components?.url else { continue }

            if let (_, response) = Self.fetch(url) {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                check("web.endpoint.\(spec.id)", status != 404, "HTTP \(status)")
            } else {
                check("web.endpoint.\(spec.id)", false, "no response from \(url)")
            }
        }

        // 9. The Mac services must answer: the on-device model and the
        //    Mac's own voice are the shell's headline features, so they
        //    belong in the gate.
        checkMacServices()

        // 10. The file picker must actually fire.
        if let fixture = Self.fixtureURL() {
            controller.selftestFileURL = fixture
            check("selftest.fixture", true, fixture.lastPathComponent)
        } else {
            check("selftest.fixture", false, "no fixture found — pass --fixture <path>")
        }

        controller.triggerAddBookForTest()

        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
            self?.afterPicker()
        }
    }

    /// The native modules must switch cleanly, and the suite's own learning
    /// store — notes, favourites, read state — must survive a round trip.
    ///
    /// The store is the user's own data, so the test cleans up after itself:
    /// it creates a note under a synthetic document id and removes it again.
    private func checkLearningModules() {
        for module in SuiteModules.all where module.isAvailable {
            controller.showModuleForTest(module.id)
            check("module.\(module.id)",
                  controller.currentModuleForTest() == module.id,
                  module.title)
        }

        let learning = LearningStore.shared
        let marker = "selftest-\(UUID().uuidString)"

        let note = learning.addNote(documentId: marker, documentTitle: "Self test", body: "first")
        learning.updateNote(id: note.id, body: "second")
        check("learning.note",
              learning.note(id: note.id)?.body == "second",
              learning.note(id: note.id)?.body ?? "missing")

        learning.toggleFavourite(documentId: marker)
        let favourite = learning.isFavourite(documentId: marker)
        learning.toggleFavourite(documentId: marker)
        check("learning.favourite",
              favourite && !learning.isFavourite(documentId: marker),
              "toggles both ways")

        learning.toggleRead(documentId: marker)
        let read = learning.isRead(documentId: marker)
        learning.toggleRead(documentId: marker)
        check("learning.read",
              read && !learning.isRead(documentId: marker),
              "toggles both ways")

        learning.deleteNote(id: note.id)
        check("learning.cleanup", learning.note(id: note.id) == nil, "note removed")
    }

    /// A completed document must produce a briefing the native reader can
    /// render.
    private func checkBriefing() {
        guard let spec = controller.specsForTest.first(where: { $0.supportsLibrary }),
              let base = spec.apiBase else {
            check("briefing.fetch", false, "no library endpoint")
            return
        }

        guard let (data, _) = Self.fetch(base.appendingPathComponent("/api/documents")),
              let json = JSONTools.dictionary(from: data),
              let documents = json["documents"] as? [[String: Any]],
              let ready = documents.first(where: { ($0["status"] as? String) == "completed" }),
              let docId = ready["doc_id"] as? String else {
            check("briefing.fetch", false, "no completed document to read")
            return
        }

        guard let (docData, response) = Self.fetch(base.appendingPathComponent("/api/documents/\(docId)")),
              let status = (response as? HTTPURLResponse)?.statusCode,
              (200..<300).contains(status),
              let record = JSONTools.dictionary(from: docData),
              let briefing = Briefing(json: record) else {
            check("briefing.fetch", false, "could not read the briefing")
            return
        }

        check("briefing.fetch",
              !briefing.title.isEmpty && (!briefing.chapters.isEmpty || !briefing.executiveSummary.isEmpty),
              "\(briefing.title) — \(briefing.chapters.count) chapters")
    }

    /// The Mac helper, the on-device model and the Mac voice.
    private func checkMacServices() {        let base = MacServices.shared.baseURL

        // The provider endpoint must exist on the backend.
        if let spec = controller.specsForTest.first, let apiBase = spec.apiBase {
            var components = URLComponents(url: apiBase.appendingPathComponent("/api/provider"),
                                          resolvingAgainstBaseURL: false)
            components?.queryItems = nil
            if let url = components?.url, let (_, response) = Self.fetch(url) {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                check("provider.endpoint", status != 404, "HTTP \(status)")
            } else {
                check("provider.endpoint", false, "no response")
            }
        }

        // The helper must be up.
        guard let (statusData, statusResponse) = Self.fetch(base.appendingPathComponent("/mac/status")) else {
            check("mac.service", false, "the mac-service helper did not answer")
            return
        }
        let statusCode = (statusResponse as? HTTPURLResponse)?.statusCode ?? 0
        let statusJSON = JSONTools.dictionary(from: statusData)
        let models = (statusJSON?["foundationModels"] as? String) ?? "unavailable"
        check("mac.service", statusCode == 200, "HTTP \(statusCode), model: \(models)")

        // The on-device model must actually produce text.
        var chatRequest = URLRequest(url: base.appendingPathComponent("/mac/chat"))
        chatRequest.httpMethod = "POST"
        chatRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        chatRequest.httpBody = try? JSONSerialization.data(withJSONObject: [
            "system": "Reply with JSON only.",
            "prompt": "Return {\"ok\": true} and nothing else.",
            "json": true
        ])
        chatRequest.timeoutInterval = 120

        var chatDone = false
        var chatText = ""
        let chatSemaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: chatRequest) { data, _, _ in
            if let data, let json = JSONTools.dictionary(from: data) {
                chatText = (json["response"] as? String) ?? ""
            }
            chatDone = true
            chatSemaphore.signal()
        }.resume()
        _ = chatSemaphore.wait(timeout: .now() + 130)
        check("mac.chat", chatDone && !chatText.isEmpty,
              chatText.isEmpty ? "no response from the on-device model" : chatText.trimmed(to: 60))

        // The Mac voice must actually produce audio.
        var speakRequest = URLRequest(url: base.appendingPathComponent("/mac/speak"))
        speakRequest.httpMethod = "POST"
        speakRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        speakRequest.httpBody = try? JSONSerialization.data(withJSONObject: [
            "text": "Sloth Suite is speaking with the Mac's own voice.",
            "voice": "en-GB", "rate": 0.5
        ])
        speakRequest.timeoutInterval = 90

        var speakDone = false
        var audioBytes = 0
        var audioType = ""
        let speakSemaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: speakRequest) { data, response, _ in
            audioBytes = data?.count ?? 0
            audioType = (response as? HTTPURLResponse)?.mimeType ?? ""
            speakDone = true
            speakSemaphore.signal()
        }.resume()
        _ = speakSemaphore.wait(timeout: .now() + 100)
        check("mac.speak", speakDone && audioBytes > 1000 && audioType.contains("wav"),
              "\(audioBytes) bytes, \(audioType)")
    }

    private func afterPicker() {
        check("filepicker.fired", controller.openPanelFiredForTest,
              controller.openPanelFiredForTest ? "panel presented" : "panel never opened")

        // 10. The upload must actually reach the backend.
        //
        // The gate is that the page leaves its idle state and shows a real
        // processing stage — that proves the file picker fed the app's own
        // upload handler and the pipeline took it. Whether the briefing
        // itself has finished depends on the document length and how fast
        // the local model is, so it is reported but not asserted.
        DispatchQueue.main.asyncAfter(deadline: .now() + 45.0) { [weak self] in
            self?.afterUpload()
        }
    }

    private func afterUpload() {
        controller.evaluateAsyncForTest(Self.stageScript) { [weak self] value in
            guard let self else { return }
            let stage = (value as? String) ?? "unknown"

            self.controller.evaluateAsyncForTest(Self.deckScript) { deckValue in
                let deck = (deckValue as? Bool) == true

                let processing = ["uploading", "mapping", "synthesizing", "extracting",
                                  "crafting", "distilling", "view:"]
                let moving = processing.contains { stage.lowercased().contains($0) }
                self.check("upload.pipeline", moving || deck, "stage: \(stage)")
                self.log.write("SELFTEST INFO deck-visible=\(deck)")
                self.removeUploadedDocuments()
                self.finish()
            }
        }
    }

    // MARK: - Page probes

    private static let stageScript = """
    (() => {
      const t = document.body ? document.body.innerText : '';
      const m = t.match(/(Uploading document[^\\n]*|Mapping chapters[^\\n]*|Synthesizing[^\\n]*|Extracting[^\\n]*|Crafting[^\\n]*|Distilling[^\\n]*)/i);
      const err = t.match(/Could not read that document\\n([^\\n]{0,120})/);
      if (err) return 'ERROR: ' + err[1];
      if (m) return m[0];
      const h2 = document.querySelector('h2');
      if (h2) return 'view: ' + h2.innerText.trim().slice(0, 60);
      return 'unknown';
    })()
    """

    private static let deckScript = """
    !!document.querySelector('h2') && /Executive Thesis|reading time saved/i.test(document.body.innerText)
    """

    // MARK: - Helpers

    /// Delete the document the upload test created.
    ///
    /// A gate that runs on every build must not leave a copy of the fixture
    /// in the user's library each time it runs.
    private func removeUploadedDocuments() {
        guard let spec = controller.specsForTest.first(where: { $0.supportsLibrary }),
              let base = spec.apiBase else { return }

        guard let (data, _) = Self.fetch(base.appendingPathComponent("/api/documents")),
              let json = JSONTools.dictionary(from: data),
              let documents = json["documents"] as? [[String: Any]] else {
            return
        }

        let now = Set(documents.compactMap { $0["doc_id"] as? String })
        let added = now.subtracting(libraryIdsBeforeUpload)
        guard !added.isEmpty else { return }

        var removed = 0
        for id in added {
            let url = base.appendingPathComponent("/api/documents/\(id)")
            if Self.delete(url) { removed += 1 }
        }
        log.write("SELFTEST cleanup — removed \(removed) uploaded document(s)")
    }

    private static func fetch(_ url: URL) -> (Data, URLResponse)? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        var result: (Data, URLResponse)?
        var done = false

        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let data, let response {
                result = (data, response)
                done = true
            }
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 6)
        return done ? result : nil
    }

    /// Delete a document.
    private static func delete(_ url: URL) -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 5
        var status = 0
        var done = false

        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            done = true
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 6)
        return done && (200..<300).contains(status)
    }

    /// Locate a document to upload.
    ///
    /// The old runner hard-coded one path in `~/Downloads/dross-books`.
    /// That is now an override, with a sensible fallback.
    private static func fixtureURL() -> URL? {
        if let index = CommandLine.arguments.firstIndex(of: "--fixture"),
           CommandLine.arguments.count > index + 1 {
            let url = URL(fileURLWithPath: PathTools.expandingTilde(CommandLine.arguments[index + 1]))
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }

        let fallbacks = [
            "~/Downloads/dross-books/The-Great-God-Pan-by-Arthur-Machen.epub"
        ]
        for candidate in fallbacks {
            let url = URL(fileURLWithPath: PathTools.expandingTilde(candidate))
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }

        // Any PDF or EPUB in Downloads will do.
        let downloads = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        let contents = (try? FileManager.default.contentsOfDirectory(at: downloads,
                                                                      includingPropertiesForKeys: nil)) ?? []
        for file in contents {
            let ext = file.pathExtension.lowercased()
            if ext == "pdf" || ext == "epub" { return file }
        }
        return nil
    }
}
