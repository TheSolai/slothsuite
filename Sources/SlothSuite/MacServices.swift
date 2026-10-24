import Cocoa
import Foundation

/// Manages the bundled `mac-service` helper.
///
/// The helper exposes Apple's on-device foundation model and the Mac's own
/// speech synthesiser over a loopback HTTP API, so the wrapped apps can use
/// them without a cloud service, an API key or a payment.
///
/// It is a separate binary because FoundationModels needs a macOS 26
/// deployment target while the shell itself still supports older systems.
final class MacServices {
    static let shared = MacServices()

    struct Status {
        var foundationModels: String   // "available" | "unavailable"
        var speech: Bool
        var model: String
        var reachable: Bool
    }

    private(set) var process: Process?
    private var lastStatus: Status?
    private var lastStatusAt: Date = .distantPast

    let port: UInt16 = 8199
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    private init() {}

    // MARK: - Lifecycle

    /// Start the helper if it is not already running.
    ///
    /// A GUI app inherits a minimal PATH, so the helper is launched with an
    /// absolute path and does not rely on the environment at all.
    @discardableResult
    func launch() -> Bool {
        if let process, process.isRunning { return true }

        let executable = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/mac-service")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            Log.shared.write("mac-service not found at \(executable.path)")
            return false
        }

        let task = Process()
        task.executableURL = executable
        task.arguments = ["--port", "\(port)"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            process = task
            Log.shared.write("mac-service started (pid \(task.processIdentifier))")
            return true
        } catch {
            Log.shared.write("could not start mac-service: \(error)")
            return false
        }
    }

    func terminate() {
        guard let process, process.isRunning else { return }
        process.terminate()
        self.process = nil
        Log.shared.write("mac-service stopped")
    }

    // MARK: - Status

    /// Ask the helper what it can do. Cached for a few seconds so a health
    /// poll does not hammer it.
    func status(force: Bool = false, completion: @escaping (Status) -> Void) {
        if !force, let cached = lastStatus, Date().timeIntervalSince(lastStatusAt) < 4 {
            completion(cached)
            return
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("/mac/status"))
        request.timeoutInterval = 2

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            var status = Status(foundationModels: "unavailable", speech: false,
                                 model: "apple-foundation-models", reachable: false)
            if error == nil,
               let http = response as? HTTPURLResponse, http.statusCode == 200,
               let data = data,
               let json = JSONTools.dictionary(from: data) {
                status.foundationModels = (json["foundationModels"] as? String) ?? "unavailable"
                status.speech = (json["speech"] as? Bool) ?? false
                status.model = (json["model"] as? String) ?? "apple-foundation-models"
                status.reachable = true
            }
            self?.lastStatus = status
            self?.lastStatusAt = Date()
            DispatchQueue.main.async { completion(status) }
        }.resume()
    }

    // MARK: - Calls

    /// Run a prompt through Apple's on-device model.
    func chat(system: String,
              prompt: String,
              completion: @escaping (Result<String, Error>) -> Void) {
        var request = URLRequest(url: baseURL.appendingPathComponent("/mac/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "system": system, "prompt": prompt, "json": true
        ])
        request.timeoutInterval = 180

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data = data,
                  let json = JSONTools.dictionary(from: data),
                  let text = json["response"] as? String else {
                DispatchQueue.main.async {
                    completion(.failure(MacServiceError.badResponse))
                }
                return
            }
            DispatchQueue.main.async { completion(.success(text)) }
        }.resume()
    }

    /// Synthesise speech with the Mac's own voice.
    func speak(text: String,
               voice: String = "en-GB",
               rate: Double = 0.5,
               completion: @escaping (Result<Data, Error>) -> Void) {
        var request = URLRequest(url: baseURL.appendingPathComponent("/mac/speak"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "text": text, "voice": voice, "rate": rate
        ])
        request.timeoutInterval = 120

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data = data, !data.isEmpty else {
                DispatchQueue.main.async { completion(.failure(MacServiceError.badResponse)) }
                return
            }
            DispatchQueue.main.async { completion(.success(data)) }
        }.resume()
    }
}

enum MacServiceError: LocalizedError {
    case badResponse
    case unavailable

    var errorDescription: String? {
        switch self {
        case .badResponse: return "The Mac service did not return a usable response."
        case .unavailable: return "The Mac service is not running."
        }
    }
}
