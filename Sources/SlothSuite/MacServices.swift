import Cocoa
import Foundation
import Network

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
    /// True when this process started the helper and is therefore the one
    /// that should stop it on quit.
    private var ownsProcess = false
    private var lastStatus: Status?
    private var lastStatusAt: Date = .distantPast

    /// The watchdog timer, if it is running.
    private var watchdog: Timer?
    /// How many times in a row the helper has failed to answer.
    private var failures = 0
    /// How many times in a row a model request has failed.
    private var chatFailures = 0

    /// How many failures in a row count as wedged.
    private static let failureLimit = 2

    let port: UInt16 = 8199
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    private init() {}

    // MARK: - Lifecycle

    /// Start the helper if it is not already running.
    ///
    /// A GUI app inherits a minimal PATH, so the helper is launched with an
    /// absolute path and does not rely on the environment at all.
    ///
    /// If something is already listening on the port — a helper left over
    /// from a previous launch, say — it is adopted rather than duplicated.
    /// The second instance would fail to bind and exit, and the suite would
    /// then hold a reference to a dead process and never clean up the real
    /// one.
    @discardableResult
    func launch() -> Bool {
        if let process, process.isRunning { return true }

        if Self.isPortOpen(port) {
            Log.shared.write("mac-service already running on \(port) — adopting it")
            ownsProcess = false
            return true
        }

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
            ownsProcess = true
            Log.shared.write("mac-service started (pid \(task.processIdentifier))")
            return true
        } catch {
            Log.shared.write("could not start mac-service: \(error)")
            return false
        }
    }

    func terminate() {
        stopWatchdog()
        // Only stop the helper if this process is the one that started it.
        guard ownsProcess, let process, process.isRunning else { return }
        process.terminate()
        self.process = nil
        ownsProcess = false
        Log.shared.write("mac-service stopped")
    }

    // MARK: - The watchdog

    /// Watch the helper, and put it right if it stops answering.
    ///
    /// The helper can wedge. The on-device model is a single resource and
    /// the helper asks it one question at a time, so a request that was
    /// abandoned — the browser went away, the connection dropped — can leave
    /// the helper waiting for ever. After that `/mac/status` still says
    /// "available" because the event loop is fine, but every model request
    /// queues behind the one that will never finish.
    ///
    /// Nobody should have to notice that and restart the app by hand.
    func startWatchdog(interval: TimeInterval = 45) {
        stopWatchdog()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.probe()
        }
        // The common modes, so the watchdog keeps running while a menu is
        // open or a sheet is up.
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
        Log.shared.write("mac-service watchdog started")
    }

    func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    /// Ask the helper whether it is still there.
    private func probe() {
        status(force: true) { [weak self] status in
            guard let self else { return }
            if status.reachable {
                self.failures = 0
                return
            }
            self.failures += 1
            Log.shared.write("mac-service did not answer (\(self.failures)/\(Self.failureLimit))")
            if self.failures >= Self.failureLimit {
                self.failures = 0
                self.restart(reason: "it stopped answering")
            }
        }
    }

    /// A model request failed. That is the other sign of a wedge.
    private func noteChatFailure() {
        chatFailures += 1
        Log.shared.write("mac-service chat failed (\(chatFailures)/\(Self.failureLimit))")
        if chatFailures >= Self.failureLimit {
            chatFailures = 0
            restart(reason: "a model request never came back")
        }
    }

    /// Stop the helper and start it again.
    func restart(reason: String) {
        Log.shared.write("mac-service restarting — \(reason)")

        // The polite way first: the helper this process started.
        terminate()

        // But the helper is often started by something else — the stack
        // script, or a previous launch of the suite — in which case this
        // process does not own it and cannot stop it. It can still be found.
        Self.stopListener(on: port)

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            if self.launch() {
                Log.shared.write("mac-service restarted")
            }
        }
    }

    /// Find and stop whatever is holding the helper's port.
    ///
    /// Only the helper itself is stopped. The port is checked first, so a
    /// different program that happened to be listening would be left alone.
    private static func stopListener(on port: UInt16) {
        guard let pid = listenerPID(on: port) else { return }

        if let running = NSRunningApplication(processIdentifier: pid) {
            let path = running.executableURL?.path ?? ""
            guard path.hasSuffix("mac-service") else {
                Log.shared.write("mac-service restart skipped — port \(port) is held by \(path)")
                return
            }
        }

        kill(pid, SIGTERM)
        Log.shared.write("stopped the mac-service on port \(port) (pid \(pid))")
    }

    /// The process listening on a loopback port, if any.
    private static func listenerPID(on port: UInt16) -> pid_t? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = text.split(separator: "\n").first else { return nil }
        return pid_t(first.trimmingCharacters(in: .whitespaces))
    }

    /// Is something listening on this loopback port?
    private static func isPortOpen(_ port: UInt16, timeout: TimeInterval = 0.4) -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
        let connection = NWConnection(to: endpoint, using: .tcp)
        let queue = DispatchQueue(label: "slothsuite.macsvc.portcheck")
        let semaphore = DispatchSemaphore(value: 0)
        let box = MacPortFlag()

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                box.set()
                connection.cancel()
                semaphore.signal()
            case .failed, .cancelled:
                connection.cancel()
                semaphore.signal()
            default:
                break
            }
        }

        connection.start(queue: queue)
        _ = semaphore.wait(timeout: .now() + timeout)
        connection.cancel()
        return box.value
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

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error {
                self?.noteChatFailure()
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data = data,
                  let json = JSONTools.dictionary(from: data),
                  let text = json["response"] as? String else {
                self?.noteChatFailure()
                DispatchQueue.main.async {
                    completion(.failure(MacServiceError.badResponse))
                }
                return
            }
            self?.chatFailures = 0
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

/// A tiny thread-safe boolean, used to make sure the port probe only
/// signals its semaphore once.
private final class MacPortFlag {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func set() {
        lock.lock(); defer { lock.unlock() }
        stored = true
    }
}
