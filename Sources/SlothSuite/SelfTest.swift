import Cocoa
import Foundation
import WebKit

/// Headless verification of the suite.
///
/// The original `--selftest` logged what it observed and then always called
/// `exit(0)`, so it could never fail — a broken build would still report
/// success. This runner turns every observation into an assertion and exits
/// non-zero when something is wrong, which makes it usable as a build gate.
final class SelfTestRunner {
    private let controller: SuiteController
    private let log = Log.shared
    private var failures = 0
    private var checks = 0

    init(controller: SuiteController) {
        self.controller = controller
    }

    // MARK: - Assertion helpers

    private func check(_ name: String, _ passed: Bool, _ detail: String) {
        checks += 1
        if !passed { failures += 1 }
        let mark = passed ? "PASS" : "FAIL"
        log.writeSync("SELFTEST \(mark) \(name) — \(detail)")
    }

    private func finish() {
        log.writeSync("SELFTEST end — \(checks - failures)/\(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Run

    func begin() {
        log.writeSync("SELFTEST begin")
        log.mirrorToStderr(true)

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

        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            self?.continueRun()
        }
    }

    private func continueRun() {
        let activeID = controller.currentSpecForTest.id
        let webView = controller.webViewForTest(activeID)

        check("webview.url", webView?.url?.absoluteString != nil,
              webView?.url?.absoluteString ?? "no url")
        check("webview.title", !(webView?.title ?? "").isEmpty,
              webView?.title ?? "untitled")

        // 6. The bridge must work — this is the contract that replaced DOM
        //    scraping, so a silent failure here matters.
        let bridge = controller.bridgeForTest(activeID)
        var bridgeOK = false
        var bridgeDetail = "no bridge"
        if let bridge, let webView {
            bridge.perform("status", in: webView) { result in
                switch result {
                case .success(let value):
                    bridgeOK = true
                    bridgeDetail = String(describing: value).trimmed(to: 120)
                case .failure(let message):
                    bridgeDetail = message
                case .unsupported(let message):
                    bridgeDetail = message
                }
            }
        }
        // `perform` is asynchronous; give it a moment on the run loop.
        let deadline = Date().addingTimeInterval(8)
        while !bridgeOK && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        check("bridge.status", bridgeOK, bridgeDetail)

        // 7. The library endpoint must answer.
        if let spec = controller.specsForTest.first(where: { $0.supportsLibrary }),
           let base = spec.apiBase, let path = spec.libraryPath {
            let url = base.appendingPathComponent(path)
            if let (data, response) = Self.fetch(url) {
                let http = response as? HTTPURLResponse
                let json = JSONTools.dictionary(from: data)
                let documents = (json?["documents"] as? [[String: Any]])
                check("library.documents",
                      http?.statusCode == 200 && documents != nil,
                      "HTTP \(http?.statusCode ?? 0), \(documents?.count ?? -1) documents")
            } else {
                check("library.documents", false, "no response from \(url)")
            }
        }

        // 8. The web-tools endpoints must exist. A 404 means the backend has
        //    no web access wired up; a 502 means it tried and the network
        //    said no, which still proves the endpoint is wired.
        for spec in controller.specsForTest {
            guard let base = spec.apiBase else { continue }
            let url = base.appendingPathComponent("/api/web/search")
                .appending(queryItems: [URLQueryItem(name: "q", value: "local language model")])
            if let (_, response) = Self.fetch(url) {
                let http = response as? HTTPURLResponse
                let status = http?.statusCode ?? 0
                check("web.endpoint.\(spec.id)", status != 404, "HTTP \(status)")
            } else {
                check("web.endpoint.\(spec.id)", false, "no response from \(url)")
            }
        }

        // 9. The file picker must actually fire.
        if let fixture = Self.fixtureURL() {
            controller.selftestFileURL = fixture
            check("selftest.fixture", true, fixture.lastPathComponent)
        } else {
            check("selftest.fixture", false, "no fixture found — pass --fixture <path>")
        }

        controller.triggerAddBookForTest()

        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
            self?.continueAfterPicker()
        }
    }

    private func continueAfterPicker() {
        check("filepicker.fired", controller.openPanelFiredForTest,
              controller.openPanelFiredForTest ? "panel presented" : "panel never opened")

        // 10. The upload must reach the deck.
        DispatchQueue.main.asyncAfter(deadline: .now() + 75.0) { [weak self] in
            guard let self else { return }
            let stage = self.controller.pageStageForTest()
            let deck = self.controller.deckVisibleForTest()
            self.check("upload.deck", deck, "stage: \(stage)")
            self.finish()
        }
    }

    // MARK: - Helpers

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
