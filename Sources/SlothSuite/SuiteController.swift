import Cocoa
import Foundation
import ServiceManagement
import UserNotifications
import WebKit

/// The suite shell: one native window wrapping the local sloth apps.
///
/// The central change from the original single-webview design is that each
/// app keeps its own `WKWebView`. Switching apps no longer re-navigates, so
/// an in-flight synthesis, an uploaded book or a drafted plan survives.
final class SuiteController: NSObject, NSApplicationDelegate, WKNavigationDelegate,
                            WKUIDelegate, WKDownloadDelegate {

    private var config: SuiteConfig
    private let specs: [AppSpec]
    private var configProblem: String?

    private var window: NSWindow!
    private var sidebar: SidebarView!
    private var contentContainer: NSView!
    private var dropView: DropView!

    private var webViews: [String: WKWebView] = [:]
    private var bridges: [String: Bridge] = [:]
    private var loaded: Set<String> = []

    private var current: AppSpec
    private let health = HealthMonitor()
    private var stackManager: StackManager!
    private var libraryTimer: Timer?

    /// Set when the stack was started on our behalf, so the active page can
    /// be reloaded once the backend actually answers.
    private var pendingReloadAfterStackStart = false
    private var webAccessEnabled: Bool?
    private var aiProvider = "ollama"
    private var macModelAvailable = false

    /// When set, the file picker resolves to this file instead of showing UI.
    /// Used by `--selftest` so the upload path can be verified headlessly.
    var selftestFileURL: URL?
    private var openPanelFired = false
    var openPanelFiredForTest: Bool { openPanelFired }

    /// The runner must be retained.
    ///
    /// It was previously created as a temporary, so it deallocated the moment
    /// `begin()` returned and every `[weak self]` continuation inside it was
    /// silently nil — the run would stop after the first batch of checks and
    /// hang forever.
    private var selfTestRunner: SelfTestRunner?

    private let lastAppKey = "SlothSuite.lastAppId"

    override init() {
        let loadedConfig = SuiteConfig.load()
        self.config = loadedConfig.config
        self.configProblem = loadedConfig.problem
        self.specs = loadedConfig.config.apps
        self.current = loadedConfig.config.apps.first
            ?? AppSpec(id: "read", title: "Sloth", tagline: "", url: URL(string: "about:blank")!,
                       healthURL: URL(string: "about:blank")!, dotColorHex: "#888888",
                       apiBase: nil, libraryPath: nil, service: "read")
        super.init()

        Log.shared.configure(directory: config.resolvedLogDirectory)
        stackManager = StackManager(config: config)
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        MacServices.shared.launch()

        buildWindow()
        buildMenu()
        health.currentSpecs = specs
        health.onUpdate = { [weak self] id, status in
            self?.applyHealth(id: id, status: status)
        }
        health.onWentDown = { [weak self] id in
            self?.serviceWentDown(id)
        }
        health.start(interval: config.pollInterval)

        // Restore whichever app was open when the suite was last quit.
        if let remembered = UserDefaults.standard.string(forKey: lastAppKey),
           let spec = config.app(id: remembered) {
            current = spec
        }
        select(current)

        // Give the stack a moment to answer before deciding whether to
        // start it, so an already-running stack is never duplicated.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.startStackIfNeeded()
        }

        libraryTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.reloadLibrary()
        }

        NSApp.activate(ignoringOtherApps: true)

        if let problem = configProblem {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.presentError(title: "Configuration problem", message: problem)
            }
        }

        if CommandLine.arguments.contains("--selftest") {
            runSelfTest()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        health.stop()
        libraryTimer?.invalidate()
        MacServices.shared.terminate()
        UserDefaults.standard.set(current.id, forKey: lastAppKey)
    }

    // MARK: - Window

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 880),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered,
                          defer: false)
        window.title = "Sloth Suite"
        window.setFrameAutosaveName("SlothSuiteWindow")
        window.minSize = NSSize(width: 900, height: 600)

        sidebar = SidebarView(specs: specs)
        sidebar.onSelect = { [weak self] id in
            guard let self, let spec = self.config.app(id: id) else { return }
            self.select(spec)
        }
        sidebar.onAction = { [weak self] action in
            self?.handle(action)
        }
        sidebar.widthAnchor.constraint(equalToConstant: 244).isActive = true

        contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        dropView = DropView()
        dropView.translatesAutoresizingMaskIntoConstraints = false
        dropView.onDrop = { [weak self] url in
            self?.importDroppedFile(url)
        }

        // One webview per app. All of them stay in the hierarchy (hidden when
        // inactive) so that their pages keep their state between switches.
        for spec in specs {
            let configuration = WKWebViewConfiguration()
            configuration.userContentController.addUserScript(
                WKUserScript(source: Bridge.shim, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )

            let webView = WKWebView(frame: .zero, configuration: configuration)
            webView.navigationDelegate = self
            webView.uiDelegate = self
            webView.translatesAutoresizingMaskIntoConstraints = false
            webView.allowsBackForwardNavigationGestures = true
            if #available(macOS 13.4, *) {
                webView.isInspectable = true
            }
            // Follow the system appearance so the page does not flash a
            // different colour against the window chrome.
            webView.underPageBackgroundColor = .windowBackgroundColor

            let container = NSView()
            container.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(webView)
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor).isActive = true
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor).isActive = true
            webView.topAnchor.constraint(equalTo: container.topAnchor).isActive = true
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor).isActive = true

            contentContainer.addSubview(container)
            container.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor).isActive = true
            container.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor).isActive = true
            container.topAnchor.constraint(equalTo: contentContainer.topAnchor).isActive = true
            container.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor).isActive = true

            webViews[spec.id] = webView

            let bridge = Bridge()
            bridge.onEvent = { [weak self] name, data in
                self?.handlePageEvent(name: name, data: data)
            }
            bridges[spec.id] = bridge
            configuration.userContentController.add(bridge, name: "sloth")
        }

        let root = NSStackView()
        root.orientation = .horizontal
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false

        root.addArrangedSubview(sidebar)

        let right = NSView()
        right.translatesAutoresizingMaskIntoConstraints = false
        right.addSubview(dropView)
        dropView.leadingAnchor.constraint(equalTo: right.leadingAnchor).isActive = true
        dropView.trailingAnchor.constraint(equalTo: right.trailingAnchor).isActive = true
        dropView.topAnchor.constraint(equalTo: right.topAnchor).isActive = true
        dropView.bottomAnchor.constraint(equalTo: right.bottomAnchor).isActive = true
        right.addSubview(contentContainer)
        contentContainer.leadingAnchor.constraint(equalTo: right.leadingAnchor).isActive = true
        contentContainer.trailingAnchor.constraint(equalTo: right.trailingAnchor).isActive = true
        contentContainer.topAnchor.constraint(equalTo: right.topAnchor).isActive = true
        contentContainer.bottomAnchor.constraint(equalTo: right.bottomAnchor).isActive = true

        root.addArrangedSubview(right)

        window.contentView = root
        window.center()
        window.makeKeyAndOrderFront(nil)

        wireLibrary()
    }

    private func wireLibrary() {
        sidebar.library().onOpen = { [weak self] id in
            self?.openDocument(id)
        }
        sidebar.library().onDelete = { [weak self] id, title in
            self?.confirmDelete(id: id, title: title)
        }
    }

    // MARK: - Menu

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Sloth Suite", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Sloth Suite", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())

        let loginItem = appMenu.addItem(withTitle: "Open at Login", action: #selector(toggleOpenAtLogin(_:)), keyEquivalent: "")
        loginItem.state = Self.openAtLoginStatus ? .on : .off

        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Sloth Suite", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Add a Book…", action: #selector(addBook), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Export as Separate Files…", action: #selector(exportFiles), keyEquivalent: "e")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        for (index, spec) in specs.enumerated() {
            let item = viewMenu.addItem(withTitle: spec.title, action: #selector(selectFromMenu(_:)), keyEquivalent: "\(index + 1)")
            item.tag = index
        }
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Command Palette…", action: #selector(showCommandPalette), keyEquivalent: "k")
        viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(toggleSidebar), keyEquivalent: "\\")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Reload", action: #selector(reloadPage), keyEquivalent: "r")
        viewMenu.addItem(withTitle: "Restart Stack", action: #selector(restartStack), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Show Logs", action: #selector(showLogs), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Copy Diagnostics", action: #selector(copyDiagnostics), keyEquivalent: "d")
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Selection

    private func select(_ spec: AppSpec) {
        current = spec

        for (id, webView) in webViews {
            webView.isHidden = (id != spec.id)
        }

        // The window title used to be hardcoded to "Sloth Suite" in both
        // places it was set, so it never told you which app you were in.
        window.title = "Sloth Suite — \(spec.title)"
        window.subtitle = spec.tagline
        sidebar.setSelected(id: spec.id)

        loadIfNeeded(spec)
    }

    /// Load an app's page the first time it is shown.
    ///
    /// After that the page is never re-navigated, so switching apps keeps
    /// every piece of page state intact.
    private func loadIfNeeded(_ spec: AppSpec) {
        guard !loaded.contains(spec.id) else { return }
        loaded.insert(spec.id)
        webViews[spec.id]?.load(URLRequest(url: spec.url))
        Log.shared.write("loaded \(spec.id) — \(spec.url.absoluteString)")
    }

    @objc private func selectFromMenu(_ sender: NSMenuItem) {
        guard specs.indices.contains(sender.tag) else { return }
        select(specs[sender.tag])
    }

    // MARK: - Stack supervision

    /// Start the stack only for the services that are genuinely down.
    private func startStackIfNeeded() {
        guard stackManager.scriptAvailable else {
            Log.shared.write("stack script missing at \(stackManager.scriptURL.path)")
            sidebar.setStack("Stack: script missing")
            presentError(title: "Stack script not found",
                         message: "Expected the stack script at:\n\(stackManager.scriptURL.path)\n\n"
                            + "Set the path in:\n\(SuiteConfig.configFileURL.path)")
            return
        }

        let down = config.services.filter { service in
            !service.ports.allSatisfy { StackManager.isPortOpen($0) }
        }

        guard !down.isEmpty else { return }

        pendingReloadAfterStackStart = true
        for service in down {
            Log.shared.write("starting service \(service.id)")
            stackManager.run(action: "start", service: service.id)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            self?.reloadActivePageIfStackCameUp()
        }
    }

    /// A service that was answering has stopped answering.
    ///
    /// The original app started the stack once at launch and then never
    /// again, so a backend that died ten minutes later stayed dead.
    private func serviceWentDown(_ appId: String) {
        guard let spec = config.app(id: appId),
              let service = config.service(id: spec.service) else { return }

        Log.shared.write("service \(service.id) went down — restarting it")

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            self.stackManager.restart(service: service) { up in
                DispatchQueue.main.async {
                    self.sidebar.setStack(up ? "Stack: running" : "Stack: degraded")
                    if up, self.current.id == appId {
                        self.reloadActivePage()
                    }
                }
            }
        }
    }

    private func reloadActivePageIfStackCameUp() {
        let allUp = config.services.allSatisfy { service in
            service.ports.allSatisfy { StackManager.isPortOpen($0) }
        }
        guard allUp, pendingReloadAfterStackStart else { return }
        pendingReloadAfterStackStart = false
        reloadActivePage()
    }

    private func reloadActivePage() {
        webViews[current.id]?.reload()
    }

    // MARK: - Health

    private func applyHealth(id: String, status: HealthMonitor.Status) {
        sidebar.update(status: status, for: id)

        let all = health.allStatuses
        let allUp = !all.isEmpty && specs.allSatisfy { all[$0.id]?.ok == true }
        sidebar.setStack(allUp ? "Stack: running" : "Stack: starting…")

        let models = specs.compactMap { all[$0.id]?.ok == true ? all[$0.id]?.model : nil }
        sidebar.setAI(models.isEmpty ? "Local AI: offline" : "Local AI: " + models.joined(separator: ", "))

        if let enabled = specs.compactMap({ all[$0.id]?.webEnabled }).first {
            webAccessEnabled = enabled
            sidebar.setWeb(enabled)
        }
    }

    // MARK: - Actions

    private func handle(_ action: SidebarView.SidebarAction) {
        switch action {
        case .addBook: addBook()
        case .exportFiles: exportFiles()
        case .restartStack: restartStack()
        case .reloadPage: reloadPage()
        case .showLogs: showLogs()
        case .copyDiagnostics: copyDiagnostics()
        case .toggleWeb: toggleWebAccess()
        case .speak: speakSummary()
        case .setProvider(let provider): setProvider(provider)
        case .openDocument(let id): openDocument(id)
        case .deleteDocument(let id, let title): confirmDelete(id: id, title: title)
        }
    }

    @objc private func addBook() {
        guard let spec = specs.first(where: { $0.supportsLibrary }) else {
            presentError(title: "No library", message: "This build has no app that accepts documents.")
            return
        }

        // Switch to the reader first, then trigger its own file input so the
        // real upload handler runs rather than a side-loaded request.
        if current.id != spec.id {
            select(spec)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.triggerAddBook()
            }
            return
        }
        triggerAddBook()
    }

    private func triggerAddBook() {
        guard let spec = specs.first(where: { $0.supportsLibrary }),
              let bridge = bridges[spec.id],
              let webView = webViews[spec.id] else { return }

        bridge.perform("addBook", in: webView) { [weak self] result in
            switch result {
            case .success:
                Log.shared.write("addBook -> ok")
            case .failure(let message):
                self?.presentError(title: "Could not open the file picker", message: message)
            case .unsupported(let message):
                self?.presentError(title: "Could not open the file picker", message: message)
            }
        }
    }

    /// A file dropped on the window goes straight to the reader.
    private func importDroppedFile(_ url: URL) {
        guard let spec = specs.first(where: { $0.supportsLibrary }) else { return }
        Log.shared.write("dropped \(url.lastPathComponent)")

        if current.id != spec.id {
            select(spec)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.uploadDirectly(url, spec: spec)
        }
    }

    /// Hand a file straight to the backend's upload endpoint.
    private func uploadDirectly(_ url: URL, spec: AppSpec) {
        guard let base = spec.apiBase else { return }
        let boundary = "SlothSuite-\(UUID().uuidString)"

        var request = URLRequest(url: base.appendingPathComponent("/api/upload"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120

        let body = NSMutableData()
        let filename = url.lastPathComponent
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        if let data = try? Data(contentsOf: url) { body.append(data) }
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body as Data
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error {
                    self.presentError(title: "Could not import that file",
                                      message: error.localizedDescription)
                    return
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(code) {
                    Log.shared.write("imported \(filename)")
                    self.reloadActivePage()
                    self.reloadLibrary()
                } else {
                    let detail = (data.flatMap { JSONTools.dictionary(from: $0)?["detail"] as? String }) ?? "HTTP \(code)"
                    self.presentError(title: "Could not import that file", message: detail)
                }
            }
        }.resume()
    }

    // MARK: - Export as separate files

    @objc private func exportFiles() {
        guard let spec = specs.first(where: { $0.supportsLibrary }) else { return }

        // Prefer the page's own view of the document, so the export matches
        // what is on screen; fall back to the backend's bundle endpoint.
        guard let bridge = bridges[spec.id], let webView = webViews[spec.id] else { return }

        bridge.perform("exportBundle", in: webView) { [weak self] result in
            switch result {
            case .success(let value):
                if let dict = value as? [String: Any],
                   let files = dict["files"] as? [[String: Any]] {
                    let mapped = files.compactMap { entry -> Exporter.File? in
                        guard let name = entry["name"] as? String,
                              let content = entry["content"] as? String else { return nil }
                        return Exporter.File(name: name, content: content)
                    }
                    let title = (dict["title"] as? String) ?? "Briefing"
                    self?.writeExport(mapped, title: title)
                    return
                }
                self?.fetchBundleFromBackend(spec: spec)
            case .failure(_), .unsupported(_):
                self?.fetchBundleFromBackend(spec: spec)
            }
        }
    }

    private func fetchBundleFromBackend(spec: AppSpec) {
        guard let base = spec.apiBase else { return }
        var request = URLRequest(url: base.appendingPathComponent("/api/documents"))
        request.timeoutInterval = 5

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self else { return }
            guard error == nil,
                  let data = data,
                  let json = JSONTools.dictionary(from: data),
                  let documents = json["documents"] as? [[String: Any]] else {
                DispatchQueue.main.async {
                    self.presentError(title: "Nothing to export",
                                      message: "The library could not be read.")
                }
                return
            }

            guard let docId = documents.first(where: { ($0["status"] as? String) == "completed" })?["doc_id"] as? String
            else {
                DispatchQueue.main.async {
                    self.presentError(title: "Nothing to export",
                                      message: "There is no completed briefing to export yet.")
                }
                return
            }

            var bundleRequest = URLRequest(url: base.appendingPathComponent("/api/documents/\(docId)/bundle"))
            bundleRequest.timeoutInterval = 15
            URLSession.shared.dataTask(with: bundleRequest) { bundleData, _, bundleError in
                DispatchQueue.main.async {
                    guard bundleError == nil,
                          let bundleData = bundleData,
                          let bundle = JSONTools.dictionary(from: bundleData),
                          let files = bundle["files"] as? [[String: Any]] else {
                        self.presentError(title: "Nothing to export",
                                          message: "The export bundle could not be built.")
                        return
                    }
                    let mapped = files.compactMap { entry -> Exporter.File? in
                        guard let name = entry["name"] as? String,
                              let content = entry["content"] as? String else { return nil }
                        return Exporter.File(name: name, content: content)
                    }
                    let title = (bundle["title"] as? String) ?? "Briefing"
                    self.writeExport(mapped, title: title)
                }
            }.resume()
        }.resume()
    }

    private func writeExport(_ files: [Exporter.File], title: String) {
        Exporter.write(files: files, suggestedName: Exporter.folderName(for: title)) { [weak self] result in
            switch result {
            case .success(let folder):
                NSWorkspace.shared.open(folder)
                self?.setDockBadge(nil)
            case .failure(let error):
                self?.presentError(title: "Export failed", message: error.localizedDescription)
            }
        }
    }

    // MARK: - Speak the summary

    /// Speak the current briefing using the Mac's own voice.
    private func speakSummary() {
        guard let spec = specs.first(where: { $0.supportsLibrary }), let base = spec.apiBase else { return }

        MacServices.shared.status { [weak self] status in
            guard let self else { return }
            guard status.reachable, status.speech else {
                self.presentError(title: "The Mac voice is not available",
                                  message: "Start Sloth Suite from the Applications folder so the Mac service can run.")
                return
            }

            var request = URLRequest(url: base.appendingPathComponent("/api/documents"))
            request.timeoutInterval = 5
            URLSession.shared.dataTask(with: request) { data, _, _ in
                guard let data = data,
                      let json = JSONTools.dictionary(from: data),
                      let documents = json["documents"] as? [[String: Any]],
                      let docId = documents.first(where: { ($0["status"] as? String) == "completed" })?["doc_id"] as? String
                else {
                    DispatchQueue.main.async {
                        self.presentError(title: "Nothing to speak",
                                          message: "There is no completed briefing yet.")
                    }
                    return
                }

                var docRequest = URLRequest(url: base.appendingPathComponent("/api/documents/\(docId)"))
                docRequest.timeoutInterval = 10
                URLSession.shared.dataTask(with: docRequest) { docData, _, _ in
                    guard let docData = docData,
                          let record = JSONTools.dictionary(from: docData),
                          let chapters = record["chapters"] as? [[String: Any]] else {
                        DispatchQueue.main.async {
                            self.presentError(title: "Nothing to speak",
                                              message: "The briefing could not be read.")
                        }
                        return
                    }

                    let script = chapters.compactMap { $0["audio_script"] as? String }
                        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                        .joined(separator: " ")

                    guard !script.isEmpty else {
                        DispatchQueue.main.async {
                            self.presentError(title: "Nothing to speak",
                                              message: "This briefing has no audio script.")
                        }
                        return
                    }

                    DispatchQueue.main.async {
                        self.setDockBadge("🔊")
                        MacServices.shared.speak(text: script) { result in
                            DispatchQueue.main.async {
                                self.setDockBadge(nil)
                                if case .failure(let error) = result {
                                    self.presentError(title: "Could not speak the summary",
                                                      message: error.localizedDescription)
                                }
                            }
                        }
                    }
                }.resume()
            }.resume()
        }
    }

    // MARK: - AI provider

    private func setProvider(_ provider: String) {
        guard let spec = specs.first, let base = spec.apiBase else { return }

        var request = URLRequest(url: base.appendingPathComponent("/api/provider"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["provider": provider])
        request.timeoutInterval = 5

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.presentError(title: "Could not switch the AI provider",
                                      message: error.localizedDescription)
                    return
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(code) else {
                    self.presentError(title: "Could not switch the AI provider",
                                      message: "The backend answered HTTP \(code).")
                    return
                }
                if let json = data.flatMap(JSONTools.dictionary),
                   let chosen = json["provider"] as? String {
                    self.aiProvider = chosen
                }
                self.refreshProvider()
            }
        }.resume()
    }

    /// Read the provider and the Mac model's availability from the backend.
    private func refreshProvider() {
        guard let spec = specs.first, let base = spec.apiBase else { return }

        var request = URLRequest(url: base.appendingPathComponent("/api/provider"))
        request.timeoutInterval = 5

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self else { return }
            var provider = self.aiProvider
            var macReachable = false
            if let json = data.flatMap(JSONTools.dictionary) {
                provider = (json["provider"] as? String) ?? provider
                macReachable = (json["macServiceReachable"] as? Bool) ?? false
            }
            DispatchQueue.main.async {
                self.aiProvider = provider
                self.macModelAvailable = macReachable
                self.sidebar.setProvider(provider, macAvailable: macReachable)
            }
        }.resume()

        MacServices.shared.status { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                self.macModelAvailable = status.reachable && status.foundationModels == "available"
                self.sidebar.setMacModel(status.foundationModels == "available"
                                          ? "Mac model: ready" : "Mac model: unavailable")
                self.sidebar.setProvider(self.aiProvider, macAvailable: self.macModelAvailable)
            }
        }
    }

    // MARK: - Web access

    /// Turn web lookups on or off for the backend.
    private func toggleWebAccess() {
        let target = !(webAccessEnabled ?? false)
        guard let spec = specs.first, let base = spec.apiBase else { return }

        var request = URLRequest(url: base.appendingPathComponent("/api/web/toggle"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["enabled": target])
        request.timeoutInterval = 5

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    Log.shared.write("web toggle failed: \(error.localizedDescription)")
                    self.presentError(title: "Could not change the web setting",
                                      message: error.localizedDescription)
                    return
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(code) else {
                    self.presentError(title: "Could not change the web setting",
                                      message: "The backend answered HTTP \(code).")
                    return
                }
                self.webAccessEnabled = target
                self.sidebar.setWeb(target)
            }
        }.resume()
    }

    // MARK: - Library

    private func openDocument(_ docId: String) {
        guard let spec = specs.first(where: { $0.supportsLibrary }) else { return }
        select(spec)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self,
                  let bridge = self.bridges[spec.id],
                  let webView = self.webViews[spec.id] else { return }
            bridge.perform("openDocument", payload: ["id": docId], in: webView) { result in
                if case .failure(let message) = result {
                    self.presentError(title: "Could not open that document", message: message)
                }
            }
        }
    }

    private func confirmDelete(id: String, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove “\(title)” from the library?"
        alert.informativeText = "The document and its briefing are deleted from this machine. This cannot be undone."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard let spec = specs.first(where: { $0.supportsLibrary }), let base = spec.apiBase else { return }
        var request = URLRequest(url: base.appendingPathComponent("/api/documents/\(id)"))
        request.httpMethod = "DELETE"
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.presentError(title: "Could not remove that document",
                                      message: error.localizedDescription)
                    return
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(code) {
                    self.reloadLibrary()
                } else {
                    self.presentError(title: "Could not remove that document",
                                      message: "The backend answered HTTP \(code).")
                }
            }
        }.resume()
    }

    private func reloadLibrary() {
        guard let spec = specs.first(where: { $0.supportsLibrary }) else { return }
        sidebar.library().reload(spec: spec)
    }

    // MARK: - Commands

    @objc private func restartStack() {
        sidebar.setStack("Stack: restarting…")
        stackManager.run(action: "stop")
        // Wait for the ports to actually be released before starting again,
        // instead of sleeping for a fixed interval and racing the cleanup.
        let ports = config.services.flatMap { $0.ports }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = self.stackManager.waitForPortsFree(ports, timeout: 12)
            DispatchQueue.main.async {
                self.stackManager.run(action: "start")
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                    self.reloadActivePage()
                    self.sidebar.setStack("Stack: running")
                }
            }
        }
    }

    @objc private func reloadPage() {
        reloadActivePage()
    }

    @objc private func showLogs() {
        let directory = config.resolvedLogDirectory
        PathTools.ensureDirectory(directory)
        NSWorkspace.shared.open(directory)
    }

    /// Copy a diagnostics bundle to the clipboard.
    ///
    /// Everything needed to work out why something is broken, in one paste.
    @objc private func copyDiagnostics() {
        var lines: [String] = []
        lines.append("Sloth Suite diagnostics — \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Config: \(SuiteConfig.configFileURL.path)")
        lines.append("Stack script: \(stackManager.scriptURL.path) (readable: \(stackManager.scriptAvailable))")
        lines.append("AI provider: \(aiProvider)")
        lines.append("Web access: \(webAccessEnabled.map { $0 ? "on" : "off" } ?? "unknown")")

        for service in config.services {
            let ports = service.ports.map { "\($0):\(StackManager.isPortOpen($0) ? "up" : "down")" }
            lines.append("Service \(service.id): \(ports.joined(separator: ", "))")
        }

        for spec in specs {
            let status = health.status(for: spec.id)
            lines.append("Health \(spec.id): \(status.ok ? "ok" : "offline") — \(status.detail)")
        }

        MacServices.shared.status(force: true) { status in
            lines.append("Mac service: reachable=\(status.reachable) model=\(status.foundationModels)")
            lines.append("")
            lines.append("--- last 40 log lines ---")
            lines.append(contentsOf: Log.shared.tail(40))

            let text = lines.joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            Log.shared.write("diagnostics copied to the clipboard")
            DispatchQueue.main.async {
                self.setDockBadge("📋")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.setDockBadge(nil)
                }
            }
        }
    }

    @objc private func showCommandPalette() {
        var commands: [CommandPalette.Command] = []

        for spec in specs {
            commands.append(CommandPalette.Command(
                title: "Switch to \(spec.title)",
                subtitle: spec.tagline
            ) { [weak self] in
                self?.select(spec)
            })
        }

        commands.append(CommandPalette.Command(title: "Add a book…") { [weak self] in
            self?.addBook()
        })
        commands.append(CommandPalette.Command(title: "Export as separate files…") { [weak self] in
            self?.exportFiles()
        })
        commands.append(CommandPalette.Command(title: "Speak the summary with the Mac") { [weak self] in
            self?.speakSummary()
        })
        commands.append(CommandPalette.Command(title: "Restart the stack") { [weak self] in
            self?.restartStack()
        })
        commands.append(CommandPalette.Command(title: "Reload the page") { [weak self] in
            self?.reloadPage()
        })
        commands.append(CommandPalette.Command(title: "Show the log folder") { [weak self] in
            self?.showLogs()
        })
        commands.append(CommandPalette.Command(title: "Copy diagnostics") { [weak self] in
            self?.copyDiagnostics()
        })
        commands.append(CommandPalette.Command(title: "Toggle the sidebar") { [weak self] in
            self?.toggleSidebar()
        })
        commands.append(CommandPalette.Command(
            title: aiProvider == "mac" ? "Use Ollama for AI" : "Use the Mac model for AI"
        ) { [weak self] in
            self?.setProvider(self?.aiProvider == "mac" ? "ollama" : "mac")
        })
        commands.append(CommandPalette.Command(
            title: (webAccessEnabled ?? false) ? "Turn web lookups off" : "Turn web lookups on"
        ) { [weak self] in
            self?.toggleWebAccess()
        })

        CommandPalette.show(commands: commands)
    }

    @objc private func toggleSidebar() {
        sidebar.isHidden.toggle()
    }

    // MARK: - Open at login

    private static var openAtLoginStatus: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleOpenAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                sender.state = .off
                Log.shared.write("open at login disabled")
            } else {
                try SMAppService.mainApp.register()
                sender.state = .on
                Log.shared.write("open at login enabled")
            }
        } catch {
            presentError(title: "Could not change the login item",
                         message: error.localizedDescription)
        }
    }

    // MARK: - Dock badge

    private func setDockBadge(_ text: String?) {
        NSApp.dockTile.badgeLabel = text
    }

    // MARK: - Page events

    private func handlePageEvent(name: String, data: [String: Any]) {
        Log.shared.write("page event \(name) \(data)")

        if name == "restartStack" {
            restartStack()
            return
        }

        // A long synthesis can finish while the user is in the other app.
        guard name == "synthesisComplete" || name == "planReady" else { return }
        let title = (data["title"] as? String) ?? "Your document"
        notify(title: title, body: "Ready in the app.")
    }

    private func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: UUID().uuidString,
                                                 content: content,
                                                 trigger: nil)
            center.add(request)
        }
    }

    // MARK: - Errors

    /// Show an error to the user.
    ///
    /// A modal alert blocks the main thread's run loop, which would stall the
    /// self-test, so under `--selftest` the message is logged instead.
    private func presentError(title: String, message: String) {
        Log.shared.write("error: \(title) — \(message)")
        if CommandLine.arguments.contains("--selftest") {
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Self test

    private func runSelfTest() {
        let runner = SelfTestRunner(controller: self)
        selfTestRunner = runner
        runner.begin()
    }

    // MARK: - Accessors used by the self test

    var specsForTest: [AppSpec] { specs }
    var windowForTest: NSWindow? { window }
    var sidebarForTest: SidebarView? { sidebar }
    var healthForTest: HealthMonitor { health }
    var stackForTest: StackManager { stackManager }
    var configForTest: SuiteConfig { config }
    var currentSpecForTest: AppSpec { current }

    func webViewForTest(_ id: String) -> WKWebView? { webViews[id] }
    func bridgeForTest(_ id: String) -> Bridge? { bridges[id] }

    func selectForTest(_ spec: AppSpec) { select(spec) }

    /// Trigger the reader's own file picker (used by the self-test).
    func triggerAddBookForTest() { triggerAddBook() }

    /// Evaluate JavaScript in the active page, reporting back on the main thread.
    ///
    /// The self-test is callback-driven end to end: spinning the run loop to
    /// wait for a result is what let a hung page freeze the whole run.
    func evaluateAsyncForTest(_ script: String, completion: @escaping (Any?) -> Void) {
        guard let webView = webViews[current.id] else {
            completion(nil)
            return
        }
        webView.evaluateJavaScript(script) { value, _ in
            DispatchQueue.main.async { completion(value) }
        }
    }

    func pageStageForTest() -> String {
        let script = """
        (() => {
          const t = document.body ? document.body.innerText : '';
          const m = t.match(/(Uploading document[^\\n]*|Mapping chapters[^\\n]*|Synthesizing[^\\n]*|Extracting[^\\n]*|Crafting[^\\n]*|Distilling[^\\n]*)/);
          const err = t.match(/Could not read that document\\n([^\\n]{0,120})/);
          if (err) return 'ERROR: ' + err[1];
          if (m) return m[0];
          const h2 = document.querySelector('h2');
          if (h2) return 'view: ' + h2.innerText.trim().slice(0, 60);
          return 'unknown';
        })()
        """
        return (evaluateSync(script) as? String) ?? "unknown"
    }

    func deckVisibleForTest() -> Bool {
        let script = "!!document.querySelector('h2') && /Executive Thesis|reading time saved/i.test(document.body.innerText)"
        return (evaluateSync(script) as? Bool) == true
    }

    /// Synchronous evaluate, used only by the legacy helpers above.
    private func evaluateSync(_ script: String, timeout: TimeInterval = 10) -> Any? {
        guard let webView = webViews[current.id] else { return nil }
        var result: Any?
        var done = false
        webView.evaluateJavaScript(script) { value, _ in
            result = value
            done = true
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !done && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return result
    }

    // MARK: - WKUIDelegate
    //
    // WKWebView does NOT open a file picker for `<input type="file">` unless
    // `runOpenPanelWith` is implemented. Without it the button is dead —
    // no error, no picker, nothing happens.

    func webView(_ webView: WKWebView,
                 runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        if let preset = selftestFileURL {
            Log.shared.write("openPanel -> selftest preset \(preset.lastPathComponent)")
            openPanelFired = true
            completionHandler([preset])
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.message = "Choose a PDF or EPUB to read"
        // The page only accepts PDF and EPUB. NSOpenPanel cannot express
        // "any file, but warn on the wrong one" — so allow all files and let
        // the app's own validation produce the error message.
        panel.begin { response in
            if response == .OK, let url = panel.url {
                completionHandler([url])
            } else {
                completionHandler(nil)
            }
        }
    }

    /// `target="_blank"` and `window.open` links do nothing unless this is
    /// implemented. Open them in the user's real browser instead.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            Log.shared.write("external link -> \(url.absoluteString)")
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    /// Without these, the page's `alert()` / `confirm()` / `prompt()` calls
    /// are silently swallowed — the user gets no feedback at all.
    ///
    /// Under `--selftest` they are logged instead of shown: a modal dialog
    /// would block the main thread and the run would never finish.
    private var suppressDialogs: Bool {
        CommandLine.arguments.contains("--selftest")
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        Log.shared.write("alert: \(message)")
        if suppressDialogs {
            completionHandler()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Sloth Suite"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        Log.shared.write("confirm: \(message)")
        if suppressDialogs {
            completionHandler(false)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Sloth Suite"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        Log.shared.write("prompt: \(prompt)")
        if suppressDialogs {
            completionHandler(nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Sloth Suite"
        alert.informativeText = prompt
        let field = NSTextField(string: defaultText ?? "")
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let title = webView.title ?? "(untitled)"
        Log.shared.write("loaded \(current.id) — \(title)")
        refreshProvider()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showFailure(message: error.localizedDescription, in: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showFailure(message: error.localizedDescription, in: webView)
    }

    /// The error page offers a real fix, not just "try again".
    private func showFailure(message: String, in webView: WKWebView) {
        Log.shared.write("navigation failed: \(message)")
        let html = """
        <html><head><meta charset="utf-8"><style>
        body{font-family:-apple-system,system-ui,sans-serif;background:#0f172a;color:#e2e8f0;
             display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
        .box{max-width:440px;text-align:center;padding:32px}
        h1{font-size:20px;margin:0 0 10px}
        p{color:#94a3b8;font-size:14px;line-height:1.6}
        button{background:#38bdf8;border:0;border-radius:8px;padding:9px 18px;font-weight:600;
               cursor:pointer;margin-top:8px}
        button.alt{background:#1e293b;color:#94a3b8;margin-left:8px}
        </style></head><body><div class="box">
        <h1>The sloth is still waking up.</h1>
        <p>The local backend isn't answering yet.<br>\(message)</p>
        <button onclick="window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.sloth && window.webkit.messageHandlers.sloth.postMessage({type:'event', event:'restartStack'}); this.textContent='Restarting…';">Restart the stack</button>
        <button class="alt" onclick="location.reload()">Try again</button>
        </div></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    // MARK: - Downloads
    //
    // The app exports its briefing as a Markdown file via a blob URL and an
    // `<a download>`. WKWebView silently drops those unless the download
    // policy is granted and a WKDownloadDelegate is attached.

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.canShowMIMEType == false {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView,
                 navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView,
                 navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        var destination = downloads.appendingPathComponent(suggestedFilename)
        var counter = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            let base = (suggestedFilename as NSString).deletingPathExtension
            let ext = (suggestedFilename as NSString).pathExtension
            destination = downloads.appendingPathComponent("\(base) (\(counter)).\(ext)")
            counter += 1
        }
        Log.shared.write("download -> \(destination.path)")
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        Log.shared.write("download finished")
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        Log.shared.write("download failed: \(error.localizedDescription)")
    }
}
