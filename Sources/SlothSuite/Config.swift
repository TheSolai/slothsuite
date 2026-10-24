import Cocoa
import Foundation

// MARK: - App specification

/// One wrapped application inside the suite.
struct AppSpec: Codable, Equatable {
    var id: String
    var title: String
    var tagline: String
    /// The page the webview loads.
    var url: URL
    /// The backend health endpoint used for the status dot.
    var healthURL: URL
    /// Hex colour used for the healthy state of this app's dot.
    var dotColorHex: String
    /// Backend origin, when the app exposes an HTTP API of its own.
    var apiBase: URL?
    /// Path of the library endpoint on `apiBase` (e.g. `/api/documents`).
    var libraryPath: String?
    /// Which stack service owns this app, for per-service restarts.
    var service: String

    var dotColor: NSColor { NSColor(hex: dotColorHex) ?? .secondaryLabelColor }
    var supportsLibrary: Bool { apiBase != nil && libraryPath != nil }
}

// MARK: - Services

/// A group of processes the stack script can start and stop together.
struct StackService: Codable, Equatable {
    var id: String
    var label: String
    /// Ports this service owns — used to confirm a stop actually released them.
    var ports: [Int]
}

// MARK: - Suite configuration

struct SuiteConfig: Codable, Equatable {
    var stackScript: String
    var logDirectory: String
    var pollInterval: Double
    var openAtLogin: Bool
    var services: [StackService]
    var apps: [AppSpec]

    static var configFileURL: URL {
        PathTools.applicationSupportDirectory().appendingPathComponent("config.json")
    }

    static var stackScriptURL: URL {
        URL(fileURLWithPath: PathTools.expandingTilde("~/Projects/sloth-stack.sh"))
    }

    /// The configuration used when no config file exists.
    static func builtIn() -> SuiteConfig {
        SuiteConfig(
            stackScript: "~/Projects/sloth-stack.sh",
            logDirectory: "~/Library/Logs/SlothSuite",
            pollInterval: 5.0,
            openAtLogin: false,
            services: [
                StackService(id: "read", label: "SlothRead", ports: [8300, 8100]),
                StackService(id: "mode", label: "SlothMode", ports: [5173, 3001])
            ],
            apps: [
                AppSpec(
                    id: "read",
                    title: "SlothRead",
                    tagline: "Executive decks from papers & books",
                    url: URL(string: "http://127.0.0.1:8300/")!,
                    healthURL: URL(string: "http://127.0.0.1:8100/api/health")!,
                    dotColorHex: "#2AA198",
                    apiBase: URL(string: "http://127.0.0.1:8100"),
                    libraryPath: "/api/documents",
                    service: "read"
                ),
                AppSpec(
                    id: "mode",
                    title: "SlothMode",
                    tagline: "Gentle task planning",
                    url: URL(string: "http://127.0.0.1:5173/")!,
                    healthURL: URL(string: "http://127.0.0.1:3001/api/health")!,
                    dotColorHex: "#5B5BD6",
                    apiBase: URL(string: "http://127.0.0.1:3001"),
                    libraryPath: nil,
                    service: "mode"
                )
            ]
        )
    }

    /// Load the config, falling back to the built-in defaults.
    ///
    /// Returns a non-nil `problem` when a config file existed but could not
    /// be used — the app still starts on the defaults, but says so out loud
    /// instead of silently ignoring the user's edits.
    static func load(explicitPath: String? = nil) -> (config: SuiteConfig, problem: String?) {
        let url: URL?
        if let explicitPath, !explicitPath.isEmpty {
            url = URL(fileURLWithPath: PathTools.expandingTilde(explicitPath))
        } else {
            url = configFileURL
        }

        guard let url else { return (builtIn(), nil) }

        guard FileManager.default.fileExists(atPath: url.path) else {
            if explicitPath != nil {
                return (builtIn(), "Config file not found at \(url.path) — using built-in defaults.")
            }
            // No file yet: write the defaults so there is something to edit.
            let defaults = builtIn()
            if let data = try? JSONEncoder.pretty.encode(defaults) {
                try? data.write(to: url, options: .atomic)
            }
            return (defaults, nil)
        }

        do {
            let data = try Data(contentsOf: url)
            var config = try JSONDecoder().decode(SuiteConfig.self, from: data)
            config.stackScript = PathTools.expandingTilde(config.stackScript)
            config.logDirectory = PathTools.expandingTilde(config.logDirectory)
            return (config, nil)
        } catch {
            return (builtIn(), "Could not read \(url.path): \(error.localizedDescription) — using built-in defaults.")
        }
    }

    func service(id: String) -> StackService? {
        services.first { $0.id == id }
    }

    func app(id: String) -> AppSpec? {
        apps.first { $0.id == id }
    }

    var resolvedStackScriptURL: URL {
        URL(fileURLWithPath: PathTools.expandingTilde(stackScript))
    }

    var resolvedLogDirectory: URL {
        URL(fileURLWithPath: PathTools.expandingTilde(logDirectory))
    }
}

// MARK: - JSON coding

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
