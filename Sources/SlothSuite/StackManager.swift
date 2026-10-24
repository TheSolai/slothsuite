import Cocoa
import Foundation
import Network

/// Controls the local stack that the wrapped apps run on.
///
/// The old behaviour was a single `didAutoStart` flag: the stack was started
/// once per app launch and never again, and one dead backend caused the
/// *whole* stack to be relaunched. This class tracks services individually
/// and waits for the filesystem/network to actually settle rather than
/// sleeping for a fixed interval and hoping.
final class StackManager {
    private var config: SuiteConfig
    private let log: Log

    /// Services with an action currently in flight, so a restart request
    /// cannot start a second copy of the same service.
    private var inFlight: Set<String> = []
    private let stateLock = NSLock()

    init(config: SuiteConfig, log: Log = .shared) {
        self.config = config
        self.log = log
    }

    var scriptURL: URL { config.resolvedStackScriptURL }

    var scriptAvailable: Bool {
        FileManager.default.isReadableFile(atPath: scriptURL.path)
    }

    /// Look for the stack script in the places it usually lives.
    ///
    /// A stale path in the config file — a moved project, a renamed
    /// machine — should not stop the suite from starting its stack. This
    /// finds the script and adopts it.
    func recoverScriptPath() -> Bool {
        let candidates = [
            PathTools.expandingTilde("~/Projects/sloth-stack.sh"),
            PathTools.expandingTilde("~/Projects/SlothSuite/sloth-stack.sh"),
            PathTools.expandingTilde("~/Projects/SlothSuite/../sloth-stack.sh")
        ]

        for candidate in candidates {
            guard FileManager.default.isReadableFile(atPath: candidate) else { continue }
            let resolved = URL(fileURLWithPath: candidate).standardizedFileURL.path
            config.stackScript = resolved
            log.write("recovered the stack script path to \(resolved)")
            return true
        }
        return false
    }

    // MARK: - Running the script

    /// Run `sloth-stack.sh <action> [service]`.
    ///
    /// Returns false when the script is missing or the process could not be
    /// launched — the caller must surface that rather than fail silently.
    @discardableResult
    func run(action: String, service: String? = nil) -> Bool {
        guard scriptAvailable else {
            log.write("stack script not found at \(scriptURL.path)")
            return false
        }

        var arguments = [scriptURL.path, action]
        if let service { arguments.append(service) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = arguments

        // Capture output instead of discarding it: when a service fails to
        // come back up, this is the only place the reason exists.
        let outputURL = config.resolvedLogDirectory.appendingPathComponent("stack-\(action).log")
        PathTools.ensureDirectory(config.resolvedLogDirectory)
        if !FileManager.default.fileExists(atPath: outputURL.path) {
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        }

        var outputHandle: FileHandle?
        if let handle = try? FileHandle(forWritingTo: outputURL) {
            handle.seekToEndOfFile()
            handle.write(Data("\n--- \(action) \(service ?? "all") ---\n".utf8))
            process.standardOutput = handle
            process.standardError = handle
            outputHandle = handle
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }

        do {
            try process.run()
            // The child holds its own duplicate of the descriptor, so the
            // parent's copy can be closed now.
            try? outputHandle?.close()
            log.write("ran sloth-stack.sh \(action) \(service ?? "all")")
            return true
        } catch {
            try? outputHandle?.close()
            log.write("failed to run sloth-stack.sh \(action): \(error)")
            return false
        }
    }

    // MARK: - Lifecycle

    /// Start every service that is not already answering.
    func startMissingServices() {
        for service in config.services {
            guard !servicePortsOpen(service) else { continue }
            log.write("starting service \(service.id)")
            run(action: "start", service: service.id)
            _ = waitForService(service, timeout: 25)
        }
    }

    /// Restart a single service: stop it, wait for its ports to be
    /// released, then start it again.
    ///
    /// The old code slept a fixed 1.5 seconds between stop and start, which
    /// raced the script's own port cleanup and could lose the port race
    /// against `vite --strictPort`.
    func restart(service: StackService, completion: ((Bool) -> Void)? = nil) {
        stateLock.lock()
        let alreadyRunning = inFlight.contains(service.id)
        if !alreadyRunning { inFlight.insert(service.id) }
        stateLock.unlock()

        guard !alreadyRunning else {
            log.write("restart of \(service.id) already in progress")
            completion?(false)
            return
        }

        run(action: "stop", service: service.id)
        let freed = waitForPortsFree(service.ports, timeout: 12)
        if !freed {
            log.write("ports for \(service.id) did not free up in time")
        }

        run(action: "start", service: service.id)
        let up = waitForService(service, timeout: 30)

        stateLock.lock()
        inFlight.remove(service.id)
        stateLock.unlock()

        completion?(up)
    }

    func stopAll() {
        run(action: "stop")
    }

    // MARK: - Waiting

    /// Wait until every port of a service is free.
    func waitForPortsFree(_ ports: [Int], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if ports.allSatisfy({ !Self.isPortOpen($0) }) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return ports.allSatisfy({ !Self.isPortOpen($0) })
    }

    /// Wait until a service's ports are all accepting connections.
    func waitForService(_ service: StackService, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if servicePortsOpen(service) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return servicePortsOpen(service)
    }

    private func servicePortsOpen(_ service: StackService) -> Bool {
        service.ports.allSatisfy { Self.isPortOpen($0) }
    }

    // MARK: - Port probing

    /// Is something listening on this loopback port?
    ///
    /// Used to tell "the service is up" from "the port is still held by a
    /// process we failed to kill" — the two need different reactions.
    static func isPortOpen(_ port: Int, host: String = "127.0.0.1", timeout: TimeInterval = 0.5) -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let connection = NWConnection(to: endpoint, using: .tcp)
        let queue = DispatchQueue(label: "slothsuite.portcheck")
        let semaphore = DispatchSemaphore(value: 0)
        let box = AtomicFlag()

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
}

/// A tiny thread-safe boolean, used to make sure the port probe only
/// signals its semaphore once.
private final class AtomicFlag {
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
