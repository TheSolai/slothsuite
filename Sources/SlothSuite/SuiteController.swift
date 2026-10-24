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

    /// When set, the file picker resolves to this file instead of showing UI.
    /// Used by `--selftest` so the upload path can be verified headlessly.
    var selftestFileURL: URL?
    private var openPanelFired = false
    var openPanelFiredForTest: Bool { openPanelFired }

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

        // One webview per app. All of them stay in the hierarchy (hidden when
        // inactive) so that their pages keep their state between switches.
        for spec in specs {
            // The bridge shim is injected at document start so it is present
            // even on a page that has not been updated to the new contract.
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
        root.addArrangedSubview(contentContainer)

        window.contentView = root
        window.center()
        window.makeKeyAndOrderFront(nil)
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
        fileMenu.addItem(withTitle: "Export Briefing (Markdown)…", action: #selector(exportBriefing), keyEquivalent: "e")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        for (index, spec) in specs.enumerated() {
            let item = viewMenu.addItem(withTitle: spec.title, action: #selector(selectFromMenu(_:)), keyEquivalent: "\(index + 1)")
            item.tag = index
        }
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Reload", action: #selector(reloadPage), keyEquivalent: "r")
        viewMenu.addItem(withTitle: "Restart Stack", action: #selector(restartStack), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Show Logs", action: #selector(showLogs), keyEquivalent: "")
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
        let webView = webViews[current.id]
        webView?.reload()
    }

    // MARK: - Health

    private func applyHealth(id: String, status: HealthMonitor.Status) {
        sidebar.update(status: status, for: id)

        let all = health.allStatuses
        let allUp = !all.isEmpty && specs.allSatisfy { all[$0.id]?.ok == true }
        sidebar.setStack(allUp ? "Stack: running" : "Stack: starting…")

        let models = specs.compactMap { all[$0.id]?.ok == true ? all[$0.id]?.model : nil }
        sidebar.setAI(models.isEmpty ? "Local AI: offline" : "Local AI: " + models.joined(separator: ", "))

        // The web flag is reported by the backends; show whichever app
        // answered last, since they share the same setting.
        if let enabled = specs.compactMap({ all[$0.id]?.webEnabled }).first {
            webAccessEnabled = enabled
            sidebar.setWeb(enabled)
        }
    }

    // MARK: - Actions

    private func handle(_ action: SidebarView.SidebarAction) {
        switch action {
        case .addBook: addBook()
        case .exportBriefing: exportBriefing()
        case .restartStack: restartStack()
        case .reloadPage: reloadPage()
        case .showLogs: showLogs()
        case .toggleWeb: toggleWebAccess()
        case .openDocument(let id): openDocument(id)
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

    @objc private func exportBriefing() {
        guard let bridge = bridges[current.id],
              let webView = webViews[current.id] else { return }
        bridge.perform("exportBriefing", in: webView) { [weak self] result in
            switch result {
            case .success:
                Log.shared.write("export -> ok")
            case .failure(let message):
                self?.presentError(title: "Export failed", message: message)
            case .unsupported(let message):
                self?.presentError(title: "Export failed", message: message)
            }
        }
    }

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

    /// Turn web lookups on or off for both backends.
    private func toggleWebAccess() {
        let target = !(webAccessEnabled ?? false)
        for spec in specs {
            guard let base = spec.apiBase else { continue }
            var request = URLRequest(url: base.appendingPathComponent("/api/web/toggle"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["enabled": target])
            request.timeoutInterval = 5

            URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
                if let error {
                    Log.shared.write("web toggle failed for \(spec.id): \(error.localizedDescription)")
                } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    Log.shared.write("web toggle rejected by \(spec.id): HTTP \(http.statusCode)")
                }
                DispatchQueue.main.async {
                    self?.webAccessEnabled = target
                    self?.sidebar.setWeb(target)
                }
            }.resume()
        }
    }

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

    private func reloadLibrary() {
        guard let spec = specs.first(where: { $0.supportsLibrary }) else { return }
        sidebar.library().reload(spec: spec)
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

    // MARK: - Page events

    private func handlePageEvent(name: String, data: [String: Any]) {
        Log.shared.write("page event \(name) \(data)")

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

    private func presentError(title: String, message: String) {
        Log.shared.write("error: \(title) — \(message)")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Self test

    private func runSelfTest() {
        SelfTestRunner(controller: self).begin()
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

    func setStackLabelForTest(_ text: String) { sidebar.setStack(text) }
    func setAILabelForTest(_ text: String) { sidebar.setAI(text) }

    /// Evaluate JavaScript in the active page and return the result.
    func evaluateForTest(_ script: String, timeout: TimeInterval = 10) -> Any? {
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
        return (evaluateForTest(script) as? String) ?? "unknown"
    }

    func deckVisibleForTest() -> Bool {
        let script = "!!document.querySelector('h2') && /Executive Thesis|reading time saved/i.test(document.body.innerText)"
        return (evaluateForTest(script) as? Bool) == true
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
    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        Log.shared.write("alert: \(message)")
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
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showFailure(message: error.localizedDescription, in: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showFailure(message: error.localizedDescription, in: webView)
    }

    private func showFailure(message: String, in webView: WKWebView) {
        Log.shared.write("navigation failed: \(message)")
        let html = """
        <html><head><meta charset="utf-8"><style>
        body{font-family:-apple-system,system-ui,sans-serif;background:#0f172a;color:#e2e8f0;
             display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
        .box{max-width:420px;text-align:center;padding:32px}
        h1{font-size:20px;margin:0 0 10px}
        p{color:#94a3b8;font-size:14px;line-height:1.6}
        button{background:#38bdf8;border:0;border-radius:8px;padding:9px 18px;font-weight:600;
               cursor:pointer;margin-top:8px}
        </style></head><body><div class="box">
        <h1>The sloth is still waking up.</h1>
        <p>The local backend isn't answering yet.<br>\(message)</p>
        <button onclick="location.reload()">Try again</button>
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
