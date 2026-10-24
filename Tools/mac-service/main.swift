// mac-service — the Mac's own AI services, exposed over a loopback HTTP API.
//
// The Sloth Suite shell bundles and launches this helper. It gives the
// wrapped apps two things they cannot do for themselves:
//
//   * Apple's on-device foundation model, so a document can be summarised
//     without Ollama and without anything leaving the machine.
//   * Native speech synthesis, so the 60-second recaps are spoken by the
//     Mac's own voice instead of a cloud TTS API that needs a key.
//
// It binds to 127.0.0.1 only. It is a separate binary rather than part of
// the shell because FoundationModels needs a macOS 26 deployment target,
// and the shell itself still supports older systems.
//
//   POST /mac/chat   {system, prompt, json}  -> {response, provider}
//   POST /mac/speak  {text, voice, rate}      -> audio/wav
//   GET  /mac/status                         -> {foundationModels, speech, model}

import AVFoundation
import Foundation
import FoundationModels
import Network

// MARK: - Configuration

let port: UInt16 = {
    if let index = CommandLine.arguments.firstIndex(of: "--port"),
       CommandLine.arguments.count > index + 1,
       let parsed = UInt16(CommandLine.arguments[index + 1]) {
        return parsed
    }
    return 8199
}()

let allowedOrigins = [
    "http://127.0.0.1:8300",
    "http://localhost:8300",
    "http://127.0.0.1:5173",
    "http://localhost:5173"
]

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("[\(stamp)] mac-service: \(message)\n".utf8))
}

// MARK: - HTTP plumbing

struct Request {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    func json() -> [String: Any] {
        guard !body.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: body),
              let dict = object as? [String: Any] else { return [:] }
        return dict
    }
}

func respond(_ connection: NWConnection,
             status: Int,
             contentType: String,
             body: Data,
             extraHeaders: [String: String] = [:]) {
    let reason: String
    switch status {
    case 200: reason = "OK"
    case 400: reason = "Bad Request"
    case 404: reason = "Not Found"
    case 405: reason = "Method Not Allowed"
    case 500: reason = "Internal Server Error"
    case 503: reason = "Service Unavailable"
    default: reason = "OK"
    }

    var headers: [String: String] = [
        "Content-Type": contentType,
        "Content-Length": "\(body.count)",
        "Connection": "close",
        "Access-Control-Allow-Origin": allowedOrigins.first ?? "http://127.0.0.1:8300",
        "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type"
    ]
    for (key, value) in extraHeaders { headers[key] = value }

    var head = "HTTP/1.1 \(status) \(reason)\r\n"
    for (key, value) in headers { head += "\(key): \(value)\r\n" }
    head += "\r\n"

    var payload = Data(head.utf8)
    payload.append(body)
    connection.send(content: payload, completion: .contentProcessed { _ in
        connection.cancel()
    })
}

func respondJSON(_ connection: NWConnection, status: Int, _ object: [String: Any]) {
    let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    respond(connection, status: status, contentType: "application/json", body: data)
}

// MARK: - Foundation Models

/// Lets one caller through at a time.
private final class AsyncGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 1)

    func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // The wait happens on a background thread, so the caller's thread
            // is never blocked.
            DispatchQueue.global().async {
                self.semaphore.wait()
                continuation.resume()
            }
        }
    }

    func release() {
        semaphore.signal()
    }
}

enum MacModel {
    /// The model is asked one question at a time.
    ///
    /// The on-device model is a single resource. Two questions at once make
    /// both of them slow — the second can take twice as long as the first —
    /// and neither is worth the wait. They take their turn here instead.
    private static let gate = AsyncGate()

    static var isAvailable: Bool {
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
        return false
    }

    /// Run a prompt through Apple's on-device model.
    static func chat(system: String, prompt: String) async throws -> String {
        guard #available(macOS 26.0, *) else {
            throw MacError.unavailable("The on-device model needs macOS 26 or later.")
        }
        guard SystemLanguageModel.default.availability == .available else {
            throw MacError.unavailable("The on-device model is not available on this Mac right now.")
        }

        await gate.acquire()
        do {
            let session = LanguageModelSession(instructions: system)
            let response = try await session.respond(to: prompt)
            gate.release()
            return response.content
        } catch {
            gate.release()
            throw error
        }
    }

    /// Load the model now, so the first question does not pay for it.
    ///
    /// The first question to reach a cold model waits for the model to load —
    /// over a minute, on this Mac. Loading it when the helper starts means
    /// the helper is ready before anyone asks it anything.
    static func warmUp() async -> String {
        guard #available(macOS 26.0, *) else { return "the on-device model needs macOS 26 or later" }
        guard SystemLanguageModel.default.availability == .available else {
            return "the on-device model is not available on this Mac right now"
        }

        await gate.acquire()
        defer { gate.release() }
        let session = LanguageModelSession(instructions: "You are a helpful assistant.")
        do {
            let response = try await session.respond(to: "Say hello.")
            return "ready in \(response.content.count) characters"
        } catch {
            return "could not load the model: \(error.localizedDescription)"
        }
    }
}

enum MacError: Error {
    case unavailable(String)
    case badRequest(String)

    var message: String {
        switch self {
        case .unavailable(let text): return text
        case .badRequest(let text): return text
        }
    }
}

// MARK: - Speech synthesis

enum MacSpeech {
    /// Synthesise `text` and return a WAV file.
    static func speak(text: String, voice: String, rate: Double) async throws -> Data {
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: voice)
        // AVSpeechUtteranceDefaultSpeechRate is the natural pace; 0.5 in the
        // web Speech API is roughly the same ballpark.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(max(0.1, min(2.0, rate / 0.5)))

        let collector = BufferCollector()

        // `write` never sets `isSpeaking`, so completion has to come from the
        // callback: the synthesiser delivers a final empty buffer when it is
        // done. A stall detector covers the case where it does not.
        await MacSpeech.start(synthesizer: synthesizer, utterance: utterance, collector: collector)

        let deadline = Date().addingTimeInterval(60)
        while !collector.isFinished && !collector.hasStalled && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        // Let any trailing buffer land.
        try? await Task.sleep(nanoseconds: 200_000_000)

        return try collector.wavData()
    }

    /// Kick the synthesiser off on the main actor.
    @MainActor
    static func start(synthesizer: AVSpeechSynthesizer,
                      utterance: AVSpeechUtterance,
                      collector: BufferCollector) {
        synthesizer.write(utterance, toBufferCallback: { buffer in
            collector.append(buffer)
        })
    }
}

/// Collects the PCM buffers the speech synthesiser produces and turns them
/// into a canonical 16-bit PCM WAV file.
final class BufferCollector: @unchecked Sendable {
    private var buffers: [AVAudioPCMBuffer] = []
    private var finished = false
    private var lastActivity = Date()
    private let lock = NSLock()

    func append(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else {
            markFinished()
            return
        }
        lock.lock()
        defer { lock.unlock() }
        if pcm.frameLength == 0 {
            finished = true
            return
        }
        buffers.append(pcm)
        lastActivity = Date()
    }

    func markFinished() {
        lock.lock(); finished = true; lock.unlock()
    }

    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    /// True when no buffer has arrived for a while — the synthesiser
    /// sometimes never sends the final empty buffer.
    var hasStalled: Bool {
        lock.lock(); defer { lock.unlock() }
        return !buffers.isEmpty && Date().timeIntervalSince(lastActivity) > 2.0
    }

    func wavData() throws -> Data {
        lock.lock()
        let collected = buffers
        lock.unlock()

        guard let first = collected.first else {
            throw MacError.badRequest("Nothing was synthesised.")
        }

        let format = first.format
        let sampleRate = format.sampleRate
        let channels = max(1, Int(format.channelCount))
        var pcm = Data()

        for buffer in collected {
            pcm.append(Self.int16Bytes(from: buffer))
        }

        var out = Data()
        let dataSize = UInt32(pcm.count)
        let byteRate = UInt32(sampleRate) * UInt32(channels) * 2
        let blockAlign = UInt16(channels * 2)

        out.append(contentsOf: Array("RIFF".utf8))
        out.append(Self.u32(36 + dataSize))
        out.append(contentsOf: Array("WAVE".utf8))

        out.append(contentsOf: Array("fmt ".utf8))
        out.append(Self.u32(16))
        out.append(Self.u16(1))                        // PCM
        out.append(Self.u16(UInt16(channels)))
        out.append(Self.u32(UInt32(sampleRate)))
        out.append(Self.u32(byteRate))
        out.append(Self.u16(blockAlign))
        out.append(Self.u16(16))                       // bits per sample

        out.append(contentsOf: Array("data".utf8))
        out.append(Self.u32(dataSize))
        out.append(pcm)
        return out
    }

    /// Convert one PCM buffer to interleaved 16-bit little-endian samples.
    private static func int16Bytes(from buffer: AVAudioPCMBuffer) -> Data {
        let format = buffer.format
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        guard frames > 0, channels > 0 else { return Data() }

        var out = Data(capacity: frames * channels * 2)

        if format.commonFormat == .pcmFormatInt16, !format.isInterleaved,
           let source = buffer.int16ChannelData {
            for frame in 0..<frames {
                for channel in 0..<channels {
                    let value = source[channel][frame]
                    out.append(UInt8(truncatingIfNeeded: value & 0xFF))
                    out.append(UInt8(truncatingIfNeeded: (value >> 8) & 0xFF))
                }
            }
            return out
        }

        if format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
           let source = buffer.floatChannelData {
            for frame in 0..<frames {
                for channel in 0..<channels {
                    let clamped = max(-1.0, min(1.0, source[channel][frame]))
                    let value = Int(clamped * 32767.0)
                    out.append(UInt8(truncatingIfNeeded: value & 0xFF))
                    out.append(UInt8(truncatingIfNeeded: (value >> 8) & 0xFF))
                }
            }
            return out
        }

        // Anything else: fall back to the interleaved buffer list.
        let list = buffer.audioBufferList.pointee.mBuffers
        if let bytes = list.mData, list.mDataByteSize > 0 {
            out.append(Data(bytes: bytes, count: Int(list.mDataByteSize)))
        }
        return out
    }

    private static func u32(_ value: UInt32) -> Data {
        var v = value.littleEndian
        return Data(bytes: &v, count: 4)
    }

    private static func u16(_ value: UInt16) -> Data {
        var v = value.littleEndian
        return Data(bytes: &v, count: 2)
    }
}

// MARK: - Routing

func handle(_ request: Request, connection: NWConnection) {
    switch (request.method, request.path) {
    case ("GET", "/mac/status"):
        respondJSON(connection, status: 200, [
            "foundationModels": MacModel.isAvailable ? "available" : "unavailable",
            "speech": true,
            "model": "apple-foundation-models"
        ])

    case ("POST", "/mac/chat"):
        let payload = request.json()
        let system = payload["system"] as? String ?? "You are a precise analytical assistant."
        let prompt = payload["prompt"] as? String ?? ""
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            respondJSON(connection, status: 400, ["error": "prompt is required"])
            return
        }
        Task {
            do {
                let text = try await MacModel.chat(system: system, prompt: prompt)
                respondJSON(connection, status: 200, [
                    "response": text,
                    "provider": "apple-foundation-models"
                ])
            } catch let error as MacError {
                respondJSON(connection, status: 503, ["error": error.message])
            } catch {
                log("chat failed: \(error)")
                respondJSON(connection, status: 500, ["error": "\(error)"])
            }
        }

    case ("POST", "/mac/speak"):
        let payload = request.json()
        let text = payload["text"] as? String ?? ""
        let voice = payload["voice"] as? String ?? "en-GB"
        let rate = payload["rate"] as? Double ?? 0.5
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            respondJSON(connection, status: 400, ["error": "text is required"])
            return
        }
        Task {
            do {
                let wav = try await MacSpeech.speak(text: text, voice: voice, rate: rate)
                respond(connection, status: 200, contentType: "audio/wav", body: wav)
            } catch let error as MacError {
                respondJSON(connection, status: 400, ["error": error.message])
            } catch {
                log("speak failed: \(error)")
                respondJSON(connection, status: 500, ["error": "\(error)"])
            }
        }

    case ("OPTIONS", _):
        respond(connection, status: 200, contentType: "text/plain", body: Data())

    default:
        respondJSON(connection, status: 404, ["error": "no such endpoint"])
    }
}

// MARK: - Server

let queue = DispatchQueue(label: "mac-service")

/// Keeps live connections alive.
///
/// `NWConnection` releases its handler after it fires once, so a server
/// created inline would be deallocated before it ever read a request.
final class ServerRegistry {
    static let shared = ServerRegistry()
    private var servers: [Server] = []
    private let lock = NSLock()

    func add(_ server: Server) {
        lock.lock(); servers.append(server); lock.unlock()
    }

    func remove(_ server: Server) {
        lock.lock(); servers.removeAll { $0 === server }; lock.unlock()
    }
}

final class Server {
    private var buffer = Data()
    private let connection: NWConnection

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        ServerRegistry.shared.add(self)
        connection.start(queue: queue)
        receive()
    }

    private func finish() {
        ServerRegistry.shared.remove(self)
        connection.cancel()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }

            if let request = self.parse() {
                handle(request, connection: self.connection)
                return
            }

            if isComplete || error != nil {
                self.finish()
                return
            }
            self.receive()
        }
    }

    /// Parse a complete HTTP request, or return nil if more data is needed.
    private func parse() -> Request? {
        let marker = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: marker) else { return nil }

        let headerData = buffer[..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }

        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        let method = String(requestLine[0])
        let path = String(requestLine[1])

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard buffer.count >= bodyStart + length else { return nil }

        let body = Data(buffer[bodyStart..<(bodyStart + length)])
        buffer = Data(buffer[(bodyStart + length)...])
        return Request(method: method, path: path, headers: headers, body: body)
    }
}

do {
    guard let nwPort = NWEndpoint.Port(rawValue: port) else {
        log("invalid port \(port)")
        exit(1)
    }
    // Bind to the loopback interface only.
    //
    // `NWListener(using:on:)` with nothing else binds to every interface,
    // which put this service on the local network: any device on the Wi-Fi
    // could POST /mac/chat and borrow the Mac's model, or GET /mac/speak.
    // The header comment has always said this binds to 127.0.0.1 only —
    // now the code says so too.
    //
    // The endpoint has to go on the *parameters* before the listener is
    // made. Setting `listener.parameters.requiredLocalEndpoint` afterwards
    // is silently ignored, because `NWListener(using:on:)` has already
    // pinned the port to every interface by then.
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
        host: NWEndpoint.Host("127.0.0.1"),
        port: nwPort
    )
    let listener = try NWListener(using: parameters)

    listener.newConnectionHandler = { connection in
        Server(connection: connection).start()
    }
    listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
            log("listening on http://127.0.0.1:\(port)")
        case .failed(let error):
            log("listener failed: \(error)")
            exit(1)
        default:
            break
        }
    }
    listener.start(queue: queue)

    // Load the model while nothing is waiting for it. The first question
    // otherwise waits for the load, and the wait is over a minute.
    Task {
        let outcome = await MacModel.warmUp()
        log("model warm-up — \(outcome)")
    }

    // Keep the process alive.
    dispatchMain()
} catch {
    log("could not start: \(error)")
    exit(1)
}
