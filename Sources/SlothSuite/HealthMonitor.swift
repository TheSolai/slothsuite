import Cocoa
import Foundation

/// Polls every app's health endpoint on a timer.
///
/// The old poller had no notion of a *transition*: a backend that went down
/// stayed red forever with nothing trying to fix it. This one reports the
/// previous state so the controller can act on a down→up or up→down edge.
final class HealthMonitor {
    struct Status {
        var ok: Bool
        var detail: String
        var model: String?
        var webEnabled: Bool?

        static let unknown = Status(ok: false, detail: "checking…", model: nil, webEnabled: nil)
    }

    /// Called on the main thread whenever a status is refreshed.
    var onUpdate: ((String, Status) -> Void)?
    /// Called on the main thread when a service that was up goes down.
    var onWentDown: ((String) -> Void)?

    private var timer: Timer?
    private var cache: [String: Status] = [:]
    private let lock = NSLock()

    func start(interval: TimeInterval) {
        stop()
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func status(for id: String) -> Status {
        lock.lock(); defer { lock.unlock() }
        return cache[id] ?? .unknown
    }

    var allStatuses: [String: Status] {
        lock.lock(); defer { lock.unlock() }
        return cache
    }

    /// Clear a cached failure so the next poll re-checks immediately.
    func invalidate(id: String) {
        lock.lock()
        cache.removeValue(forKey: id)
        lock.unlock()
    }

    private func poll() {
        for spec in currentSpecs {
            let spec = spec
            var request = URLRequest(url: spec.healthURL)
            request.timeoutInterval = 4
            URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                let status = Self.parse(data: data, response: response, error: error)
                DispatchQueue.main.async {
                    self?.apply(spec: spec, status: status)
                }
            }.resume()
        }
    }

    /// The specs to poll. Set by the controller once the config is loaded.
    var currentSpecs: [AppSpec] = []

    private func apply(spec: AppSpec, status: Status) {
        lock.lock()
        let previous = cache[spec.id]
        cache[spec.id] = status
        lock.unlock()

        // Only announce a genuine failure transition, not the very first
        // "unknown" reading on a cold launch.
        if let previous, previous.ok, !status.ok {
            onWentDown?(spec.id)
        }

        onUpdate?(spec.id, status)
    }

    /// Parse the health payload.
    ///
    /// The two backends name the model differently — SlotRead uses
    /// `active_model`, SlothMode uses `configuredModel` — and the web-access
    /// flag is reported under `web`. Accept both rather than showing
    /// "unknown" for a backend that is plainly working.
    static func parse(data: Data?, response: URLResponse?, error: Error?) -> Status {
        guard error == nil,
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let data = data,
              let json = JSONTools.dictionary(from: data) else {
            return Status(ok: false, detail: "offline", model: nil, webEnabled: nil)
        }

        let ollama = (json["ollama"] as? [String: Any]) ?? [:]
        let model = (ollama["active_model"] as? String)
            ?? (ollama["configuredModel"] as? String)
            ?? (ollama["model"] as? String)
            ?? "unknown"
        let online = (ollama["online"] as? Bool)
            ?? (ollama["reachable"] as? Bool)
            ?? true

        var webEnabled: Bool?
        if let web = json["web"] as? [String: Any] {
            webEnabled = web["enabled"] as? Bool
        }

        return Status(
            ok: true,
            detail: online ? model : "ollama offline",
            model: online ? model : nil,
            webEnabled: webEnabled
        )
    }
}
