import Cocoa
import Foundation
import ServiceManagement
import UserNotifications
import WebKit

// MARK: - The content surface

/// The surface the modules sit on.
///
/// It paints the window background rather than staying transparent, so the
/// modules sit on a real surface instead of whatever happens to be behind
/// them. A layer's background colour is resolved when it is set, so the
/// surface has to repaint itself when the user switches macOS between light
/// and dark.
final class ContentContainerView: NSView {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    func refreshAppearance() {
        layer?.backgroundColor = resolvedCGColor(NSColor.windowBackgroundColor)
    }
}

/// The suite shell: a native window over the local learning apps.
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
    private var webContainer: NSView!
    private var libraryView: LibraryView!
    private var readerView: ReaderView!
    private var notesView: NotesView!
    private var reviewView: ReviewView!
    private var dropView: DropView!

    /// The document currently open in the reader.
    private var openDocumentId: String?

    /// The chapter the reader should open at, when one was asked for.
    private var openChapter: Int?

    /// Pins the content view to the window's content area.
    private var contentSizeConstraints: (width: NSLayoutConstraint, height: NSLayoutConstraint)?

    private var webViews: [String: WKWebView] = [:]
    private var bridges: [String: Bridge] = [:]
    private var loaded: Set<String> = []

    /// Which part of the suite is on screen: "library" or "reader".
    private var currentModule = "library"

    private var current: AppSpec
    private let health = HealthMonitor()
    private var stackManager: StackManager!
    private let library = LibraryStore.shared

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
    private let lastModuleKey = "SlothSuite.lastModule"

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
        // The dark palette has to be asked for explicitly: a process launched
        // from a terminal does not inherit the system's appearance. This has
        // to happen before the views are built, because a view resolves its
        // colours when it is created.
        if Self.wantsDarkAppearance() {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }

        MacServices.shared.launch()
        // Watch it. The helper can wedge — the on-device model is a single
        // resource — and nobody should have to notice that and restart the
        // app by hand.
        MacServices.shared.startWatchdog()

        buildWindow()
        buildToolbar()
        buildMenu()
        wireLibrary()

        health.currentSpecs = specs
        health.onUpdate = { [weak self] id, status in
            self?.applyHealth(id: id, status: status)
        }
        health.onWentDown = { [weak self] id in
            self?.serviceWentDown(id)
        }
        health.start(interval: config.pollInterval)

        // Restore where the user was.
        if let remembered = UserDefaults.standard.string(forKey: lastAppKey),
           let spec = config.app(id: remembered) {
            current = spec
        }
        let rememberedModule = UserDefaults.standard.string(forKey: lastModuleKey) ?? "library"
        showModule(rememberedModule == "reader" ? "reader" : "library")

        // Give the stack a moment to answer before deciding whether to
        // start it, so an already-running stack is never duplicated.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.startStackIfNeeded()
        }

        library.startPolling(spec: specs.first(where: { $0.supportsLibrary }))

        NSApp.activate(ignoringOtherApps: true)

        if let problem = configProblem {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.presentError(title: "Configuration problem", message: problem)
            }
        }

        if CommandLine.arguments.contains("--selftest") {
            runSelfTest()
        }

        if Self.snapshotRequest() != nil {
            runSnapshot()
        }

        // Adding a toolbar changes the window's height, so the frame is
        // asserted once more now that the whole window is assembled.
        if let frame = UserDefaults.standard.string(forKey: "SlothSuite.windowFrame") {
            let stored = NSRectFromString(frame)
            if stored.width >= 1000, stored.height >= 680 {
                window.setFrame(stored, display: true)
            }
        } else {
            window.setContentSize(NSSize(width: 1320, height: 880))
        }

        Log.shared.write("launch complete — window \(window.frame.size)")
    }

    // MARK: - Snapshot

    /// A request to render one module to a PNG.
    ///
    /// `--snapshot <module>:<path>` shows the module, renders the window and
    /// exits. It exists so the interface can be inspected without screen
    /// recording permission, which a command-line agent does not have.
    private static func snapshotRequest() -> (module: String, path: String)? {
        guard let index = CommandLine.arguments.firstIndex(of: "--snapshot"),
              CommandLine.arguments.count > index + 1 else { return nil }

        let argument = CommandLine.arguments[index + 1]
        let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    /// An optional `--size 1000x680` for the snapshot, so the layout can be
    /// checked at the window's smallest useful size.
    private static func snapshotSize() -> NSSize? {
        guard let index = CommandLine.arguments.firstIndex(of: "--size"),
              CommandLine.arguments.count > index + 1 else { return nil }

        let parts = CommandLine.arguments[index + 1].lowercased().split(separator: "x")
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]) else {
            return nil
        }
        return NSSize(width: width, height: height)
    }

    /// An optional `--action <name>` for the snapshot, so an interaction can be
    /// performed before the window is rendered.
    private static func snapshotAction() -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: "--action"),
              CommandLine.arguments.count > index + 1 else { return nil }
        return CommandLine.arguments[index + 1]
    }

    /// An optional `--dark` for the snapshot.
    ///
    /// The system appearance is a user default that a command-line process
    /// does not pick up on its own, so the dark palette could not be looked
    /// at without this.
    private static func wantsDarkAppearance() -> Bool {
        CommandLine.arguments.contains("--dark")
    }

    /// Switch the appearance while the app is running.
    ///
    /// `--toggle-dark` renders the interface after the appearance has been
    /// switched. This is the only way to see whether the views repaint
    /// themselves when macOS changes, or whether they keep the colours they
    /// were built with — which is what left the dark appearance unreadable.
    private func toggleAppearanceIfAsked() {
        guard CommandLine.arguments.contains("--toggle-dark") else { return }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        Log.shared.write("snapshot — switched to the dark appearance while running")
    }

    /// The learning store as it was before a snapshot moved it.
    ///
    /// A snapshot is the reader's own data: opening a document moves the
    /// "continue reading" pointer and writes a place. Looking at the
    /// interface must not move the reader's place, so the store is taken as
    /// it was and put back before the app exits.
    private var snapshotSavedState: LearningState?

    /// Put the reader's own data back after a snapshot.
    private func restoreSnapshotState() {
        guard let saved = snapshotSavedState else { return }
        snapshotSavedState = nil
        LearningStore.shared.restoreState(saved)
    }

    private func runSnapshot() {
        guard let request = Self.snapshotRequest() else { return }
        Log.shared.write("snapshot requested for \(request.module)")

        snapshotSavedState = LearningStore.shared.snapshotState()

        // A snapshot that never finishes must not leave the app running. A
        // stray copy of the suite holds the learning store open and uploads
        // its own fixture into the library.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) {
            Log.shared.write("snapshot failed — timed out after 30 seconds")
            self.restoreSnapshotState()
            exit(1)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }

            // A snapshot can ask for a particular window size, so the layout
            // can be checked at the window's smallest useful size.
            if let size = Self.snapshotSize(), let window = self.window {
                window.setContentSize(size)
            }

            // The audio window is a pop-out, so it needs the reader to have a
            // briefing before it can be shown.
            if request.module == "audio" {
                self.showModule("reader")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.openAudioWindowForInspection()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        // Switch after the window has been built, so the
                        // cards have to repaint themselves.
                        self.toggleAppearanceIfAsked()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            self.captureWindow(to: request.path, in: .audio)
                        }
                    }
                }
                return
            }

            self.showModule(request.module)
            Log.shared.write("snapshot module shown")

            // The term pop-up only appears under a pointer, and a snapshot
            // has no pointer, so it is opened on purpose and captured on its
            // own.
            if Self.snapshotAction() == "readerterm" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                    self.readerView.showTermPopUpForTest()
                    Log.shared.write("snapshot action — opened the term pop-up")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        self.captureWindow(to: request.path, in: .term)
                    }
                }
                return
            }

            // An action can be performed first, so the render shows the
            // result of an interaction rather than the idle state.
            if let action = Self.snapshotAction() {
                self.performSnapshotAction(action)
            }

            // Switch the appearance after the views have been built, so the
            // render shows the runtime path rather than the one that happens
            // before the views exist.
            self.toggleAppearanceIfAsked()

            // Let the module lay out and, for the reader, fetch its briefing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                self.captureWindow(to: request.path, in: .main)
            }
        }
    }

    private func performSnapshotAction(_ action: String) {
        switch action {
        case "newnote":
            notesView.pressNewNoteForTest()
            Log.shared.write("snapshot action — pressed New Note")
        case "readerlower":
            // The reader puts itself back where it was when the briefing
            // arrives, which can be after this action runs. So the scroll
            // is made once the reader has settled.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                self?.readerView.scrollBodyForTest(by: 760)
                Log.shared.write("snapshot action — scrolled the reader down")
            }
        default:
            Log.shared.write("snapshot action — unknown action \(action)")
        }
    }

    private enum SnapshotTarget {
        case main
        case audio
        case term
    }

    private func openAudioWindowForInspection() {
        guard let id = openDocumentId ?? LearningStore.shared.lastReadDocumentId,
              let briefing = BriefingStore.shared.briefing(documentId: id) else {
            Log.shared.write("snapshot failed — no briefing to open the audio window with")
            return
        }
        AudioWindowController.shared.show(briefing: briefing)
    }

    private func captureWindow(to path: String, in target: SnapshotTarget = .main) {
        // The reader's own data goes back before anything leaves, so a
        // snapshot cannot move the reader's place.
        restoreSnapshotState()

        let view: NSView?
        switch target {
        case .main:
            view = window.contentView
        case .audio:
            view = AudioWindowController.shared.contentViewForInspection
        case .term:
            view = readerView.termPopUpViewForInspection
        }
        guard let view else {
            // A snapshot that cannot find its window must still stop. Leaving
            // the app running turns a failed render into a stray process that
            // holds the learning store open and uploads its own fixture.
            Log.shared.write("snapshot failed — no view to render")
            exit(1)
        }
        view.layoutSubtreeIfNeeded()

        Log.shared.write("snapshot geometry — window \(window.frame) content \(view.frame) sidebar \(sidebar.frame)")
        Log.shared.write("library frames — \(libraryView.headerFrames())")
        Log.shared.write("view tree —\n\(Self.describeTree(view, depth: 0))")

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            Log.shared.write("snapshot failed — could not make a bitmap")
            exit(1)
        }
        view.cacheDisplay(in: view.bounds, to: rep)

        guard let data = rep.representation(using: .png, properties: [:]) else {
            Log.shared.write("snapshot failed — could not encode a PNG")
            exit(1)
        }

        do {
            try data.write(to: URL(fileURLWithPath: path))
            Log.shared.write("snapshot written to \(path)")
            exit(0)
        } catch {
            Log.shared.write("snapshot failed — \(error)")
            exit(1)
        }
    }

    /// Print the view tree with frames, so a broken layout can be read back
    /// instead of guessed at.
    private static func describeTree(_ view: NSView, depth: Int) -> String {
        var lines: [String] = []
        let pad = String(repeating: "  ", count: depth)
        let flag = view.isHidden ? " hidden" : ""
        let alpha = view.alphaValue < 1 ? " alpha=\(view.alphaValue)" : ""
        let autoresizing = view.translatesAutoresizingMaskIntoConstraints ? " AUTORESIZING" : ""
        let text: String
        if let field = view as? NSTextField {
            text = " text=\"\(field.stringValue.prefix(28))\""
        } else if let button = view as? NSButton {
            text = " title=\"\(button.title)\""
        } else {
            text = ""
        }
        lines.append("\(pad)\(type(of: view)) f=\(view.frame) flags=\(view.autoresizingMask.rawValue)\(flag)\(alpha)\(autoresizing)\(text)")

        for child in view.subviews {
            lines.append(describeTree(child, depth: depth + 1))
        }
        return lines.joined(separator: "\n")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The notes editor saves on a debounce, so the last words typed can
        // still be in flight when the app is asked to quit. The view may not
        // exist at all if the app never finished launching.
        notesView?.flushPendingSave()
        // The store writes on its own queue, which the app is about to leave
        // behind. Everything goes to the disk now, while there is still time.
        LearningStore.shared.saveNow()
        health.stop()
        library.stopPolling()
        MacServices.shared.terminate()
        AudioPlayer.shared.stop()
        saveWindowFrame()
        UserDefaults.standard.set(current.id, forKey: lastAppKey)
        UserDefaults.standard.set(currentModule, forKey: lastModuleKey)
    }

    // MARK: - Window

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 880),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered,
                          defer: false)
        window.title = "Sloth Suite"

        // The minimum size has to be set before anything else can shrink the
        // window.
        let minimum = NSSize(width: 1000, height: 680)
        window.minSize = minimum
        window.contentMinSize = minimum

        // The frame is managed by hand rather than by AppKit's autosave.
        //
        // AppKit's autosave restores a saved frame without consulting
        // `minSize`, and assigning a content view can shrink the window to
        // the content's fitting size. Either one is enough to leave the app
        // in a 573×124 window that is useless — which is exactly what
        // happened. A frame is only saved when it is big enough to be worth
        // restoring, and it is always re-checked on the way in.
        let desiredFrame = Self.restoreUsableFrame(window, minimum: minimum)

        sidebar = SidebarView(modules: SuiteModules.all)
        sidebar.onSelectModule = { [weak self] id in
            self?.showModule(id)
        }
        sidebar.onAction = { [weak self] action in
            self?.handle(action)
        }
        sidebar.widthAnchor.constraint(equalToConstant: 228).isActive = true

        contentContainer = ContentContainerView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        // The content area paints the window background rather than staying
        // transparent, so the modules sit on a real surface instead of
        // whatever happens to be behind them.
        contentContainer.wantsLayer = true
        contentContainer.layer?.backgroundColor = contentContainer.resolvedCGColor(NSColor.windowBackgroundColor)
        // The native library.
        libraryView = LibraryView()
        libraryView.translatesAutoresizingMaskIntoConstraints = false
        libraryView.onOpen = { [weak self] document in
            self?.openDocument(document)
        }
        libraryView.onExport = { [weak self] document in
            self?.performExport(document: document)
        }
        libraryView.onSpeak = { [weak self] document in
            self?.speakSummary(for: document)
        }
        libraryView.onDelete = { [weak self] document in
            self?.confirmDelete(id: document.id, title: document.title)
        }
        libraryView.onAdd = { [weak self] in
            self?.addDocument()
        }
        libraryView.onFilterChange = { filter in
            LibraryStore.shared.setFilter(filter)
        }
        libraryView.onSortChange = { sort in
            LibraryStore.shared.setSort(sort)
        }
        libraryView.onBulkRead = { markRead in
            // Every document in the library, not just the ones the current
            // filter happens to show.
            LearningStore.shared.setRead(markRead,
                                         documentIds: LibraryStore.shared.documents.map(\.id))
        }
        libraryView.onToggleFavourite = { [weak self] document in
            LearningStore.shared.toggleFavourite(documentId: document.id)
            self?.libraryView.update(documents: LibraryStore.shared.filtered)
        }
        libraryView.onToggleRead = { [weak self] document in
            LearningStore.shared.toggleRead(documentId: document.id)
            self?.libraryView.update(documents: LibraryStore.shared.filtered)
        }
        libraryView.onAddNote = { [weak self] document in
            self?.startNote(for: document)
        }
        libraryView.onContinue = { [weak self] in
            self?.continueReading()
        }

        // The native reader.
        readerView = ReaderView()
        readerView.translatesAutoresizingMaskIntoConstraints = false
        readerView.onSpeakChapter = { [weak self] chapter in
            self?.speakText(chapter.spokenText, title: chapter.title)
        }
        readerView.onSpeakAll = { [weak self] briefing in
            self?.speakEverything(briefing)
        }
        readerView.onOpenChapters = { briefing in
            AudioWindowController.shared.show(briefing: briefing)
        }
        readerView.onAddNote = { [weak self] briefing in
            guard let self else { return }
            self.startNote(forDocumentId: briefing.documentId,
                           title: briefing.title,
                           chapter: self.readerView.currentChapterIndex)
        }
        readerView.onOpenInApp = { [weak self] briefing in
            self?.openInApp(documentId: briefing.documentId)
        }
        readerView.onExport = { [weak self] briefing in
            self?.performExport(document: nil)
        }
        readerView.onChapterChanged = { [weak self] chapter in
            guard let self, let id = self.openDocumentId else { return }
            LearningStore.shared.markReading(documentId: id, chapter: chapter)
        }
        readerView.onPositionChanged = { [weak self] chapter, scroll in
            guard let self, let id = self.openDocumentId else { return }
            // The place is written to disk but not announced: it changes on
            // every scroll, and telling the whole interface about it would
            // redraw the library and the notes for nothing.
            LearningStore.shared.setPosition(documentId: id, chapter: chapter, scroll: scroll)
        }

        // The native notes module.
        notesView = NotesView()
        notesView.translatesAutoresizingMaskIntoConstraints = false
        notesView.onSelectNote = { [weak self] note in
            self?.notesView.select(noteId: note.id)
        }
        notesView.onDeleteNote = { [weak self] note in
            self?.confirmDeleteNote(note)
        }
        notesView.onChangeNoteBody = { noteId, body in
            LearningStore.shared.updateNote(id: noteId, body: body)
        }
        notesView.onCreateNote = { [weak self] in
            self?.notesView.beginNewNote()
        }
        notesView.onOpenDocument = { [weak self] note in
            guard !note.documentId.isEmpty else { return }
            // A note knows the chapter it was taken from, so it opens there.
            self?.openDocument(id: note.documentId,
                               chapter: note.chapter > 0 ? note.chapter : nil)
        }
        notesView.onSearch = { [weak self] query in
            self?.filterNotes(query)
        }

        // The review desk: spaced repetition over the notes.
        reviewView = ReviewView()
        reviewView.translatesAutoresizingMaskIntoConstraints = false
        reviewView.onRate = { noteId, remembered in
            LearningStore.shared.recordReview(noteId: noteId, remembered: remembered)
            self.refreshReview()
        }
        reviewView.onOpenNote = { [weak self] note in
            self?.showModule("notes")
            self?.notesView.show(notes: LearningStore.shared.allNotes)
            self?.notesView.select(noteId: note.id)
        }
        reviewView.onOpenDocument = { [weak self] note in
            guard !note.documentId.isEmpty else { return }
            self?.openDocument(id: note.documentId,
                               chapter: note.chapter > 0 ? note.chapter : nil)
        }

        // The wrapped web app.
        webContainer = NSView()
        webContainer.translatesAutoresizingMaskIntoConstraints = false

        dropView = DropView()
        dropView.translatesAutoresizingMaskIntoConstraints = false
        dropView.onDrop = { [weak self] url in
            self?.importDroppedFile(url)
        }

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
            // Follow the window's background so the page does not flash a
            // different colour against the chrome.
            webView.underPageBackgroundColor = .windowBackgroundColor

            let container = NSView()
            container.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(webView)
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor).isActive = true
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor).isActive = true
            webView.topAnchor.constraint(equalTo: container.topAnchor).isActive = true
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor).isActive = true

            webContainer.addSubview(container)
            container.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor).isActive = true
            container.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor).isActive = true
            container.topAnchor.constraint(equalTo: webContainer.topAnchor).isActive = true
            container.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor).isActive = true

            webViews[spec.id] = webView

            let bridge = Bridge()
            bridge.onEvent = { [weak self] name, data in
                self?.handlePageEvent(name: name, data: data)
            }
            bridges[spec.id] = bridge
            configuration.userContentController.add(bridge, name: "sloth")
        }

        contentContainer.addSubview(libraryView)
        contentContainer.addSubview(readerView)
        contentContainer.addSubview(notesView)
        contentContainer.addSubview(reviewView)
        contentContainer.addSubview(webContainer)

        libraryView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor).isActive = true
        libraryView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor).isActive = true
        libraryView.topAnchor.constraint(equalTo: contentContainer.topAnchor).isActive = true
        libraryView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor).isActive = true

        readerView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor).isActive = true
        readerView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor).isActive = true
        readerView.topAnchor.constraint(equalTo: contentContainer.topAnchor).isActive = true
        readerView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor).isActive = true

        notesView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor).isActive = true
        notesView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor).isActive = true
        notesView.topAnchor.constraint(equalTo: contentContainer.topAnchor).isActive = true
        notesView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor).isActive = true

        reviewView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor).isActive = true
        reviewView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor).isActive = true
        reviewView.topAnchor.constraint(equalTo: contentContainer.topAnchor).isActive = true
        reviewView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor).isActive = true

        webContainer.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor).isActive = true
        webContainer.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor).isActive = true
        webContainer.topAnchor.constraint(equalTo: contentContainer.topAnchor).isActive = true
        webContainer.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor).isActive = true

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

        // A plain view with explicit constraints, not a stack view.
        //
        // A horizontal `NSStackView` whose arranged subview has no intrinsic
        // content size (a bare `NSView`) does not reliably hand the remaining
        // width to that subview — the content area collapsed to a narrow
        // column while the space to its right went unused.
        // The content view keeps AppKit's own resizing — it is the window
        // that owns its frame. Turning that off left the view at whatever
        // size it was created with.
        let root = NSView()
        root.autoresizingMask = [.width, .height]
        root.addSubview(sidebar)
        root.addSubview(right)

        // The content view's size has to be pinned, or it is ambiguous: the
        // sidebar is pinned to its leading edge and the content to its
        // trailing edge, but nothing says how wide the whole thing is. Left
        // ambiguous, Auto Layout resolved it to the smallest size the
        // contents allowed and AppKit then resized the window to match —
        // which is how the app ended up 573 points wide.
        let desiredContent = window.contentRect(forFrameRect: desiredFrame).size
        let pinnedWidth = root.widthAnchor.constraint(equalToConstant: desiredContent.width)
        let pinnedHeight = root.heightAnchor.constraint(equalToConstant: desiredContent.height)
        pinnedWidth.isActive = true
        pinnedHeight.isActive = true
        contentSizeConstraints = (pinnedWidth, pinnedHeight)

        // Keep the pin in step with the window when the user resizes it.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self, let window = self.window else { return }
            let content = window.contentRect(forFrameRect: window.frame).size
            self.contentSizeConstraints?.width.constant = content.width
            self.contentSizeConstraints?.height.constant = content.height
        }

        sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor).isActive = true
        sidebar.topAnchor.constraint(equalTo: root.topAnchor).isActive = true
        sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor).isActive = true
        sidebar.widthAnchor.constraint(equalToConstant: 228).isActive = true

        right.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor).isActive = true
        right.trailingAnchor.constraint(equalTo: root.trailingAnchor).isActive = true
        right.topAnchor.constraint(equalTo: root.topAnchor).isActive = true
        right.bottomAnchor.constraint(equalTo: root.bottomAnchor).isActive = true

        window.contentView = root

        // The window is put back to the size it should be *after* it is on
        // screen.
        //
        // Showing a window makes AppKit resize it to the content view's
        // fitting size. The content view's size is not pinned to anything —
        // its subviews are pinned to its edges — so that fitting size is
        // small, and the window came up 573 points wide with the library
        // spilling across the sidebar. Re-asserting the frame afterwards is
        // what actually gives the app a usable window.
        window.setFrame(desiredFrame, display: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.setFrame(desiredFrame, display: true)
    }

    /// Put the window back to a usable size, and remember where the user put it.
    ///
    /// The frame is stored by hand rather than by `setFrameAutosaveName`,
    /// because AppKit's autosave will happily restore a frame that is far
    /// too small — and will happily save one, too. Only a frame that is big
    /// enough to be useful is ever written or read.
    private static func restoreUsableFrame(_ window: NSWindow, minimum: NSSize) -> NSRect {
        let defaults = UserDefaults.standard
        let key = "SlothSuite.windowFrame"

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let fallback = NSRect(x: 0, y: 0,
                              width: min(1320, screen.width),
                              height: min(880, screen.height))

        guard let saved = defaults.string(forKey: key) else {
            window.setContentSize(fallback.size)
            window.center()
            Log.shared.write("window frame — using the default size")
            return window.frame
        }

        let stored = NSRectFromString(saved)
        guard stored.width >= minimum.width,
              stored.height >= minimum.height else {
            window.setContentSize(fallback.size)
            window.center()
            Log.shared.write("window frame — using the default size")
            return window.frame
        }

        window.setFrame(stored, display: true)
        Log.shared.write("window frame — restored \(Int(stored.width))×\(Int(stored.height))")
        return stored
    }

    /// Remember the window's size, but only when it is worth remembering.
    private func saveWindowFrame() {
        let minimum = NSSize(width: 1000, height: 680)
        let frame = window.frame
        guard frame.width >= minimum.width, frame.height >= minimum.height else { return }
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: "SlothSuite.windowFrame")
    }

    private func wireLibrary() {
        library.onChange = { [weak self] documents in
            self?.libraryView.update(documents: documents)
            self?.refreshContinueButton()
        }

        // Favourites and read state live in the suite's own store, so the
        // library and the notes have to redraw whenever they change.
        LearningStore.shared.onChange = { [weak self] in
            guard let self else { return }
            self.libraryView.update(documents: LibraryStore.shared.filtered)
            self.notesView.show(notes: LearningStore.shared.allNotes)
            self.refreshReview()
            self.refreshContinueButton()
            self.updateWindowTitle()
        }
    }

    /// Show the "continue reading" shortcut when there is something to
    /// continue, and hide it when there is not.
    private func refreshContinueButton() {
        guard let id = LearningStore.shared.lastReadDocumentId,
              let document = LibraryStore.shared.document(id: id) else {
            libraryView.setContinue(title: nil)
            return
        }
        libraryView.setContinue(title: document.title)
    }

    // MARK: - Toolbar

    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "SlothSuiteToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    // MARK: - Modules

    /// Switch between the parts of the suite.
    private func showModule(_ id: String) {
        guard let module = SuiteModules.module(id: id), module.isAvailable else { return }
        // Whatever was typed into the notes editor belongs to the note, even
        // if the user walks away before the debounced save fires.
        notesView.flushPendingSave()
        // The same goes for the reader's place: it is saved when the reader
        // is put away, so it is remembered even if the reader was still
        // moving when they left.
        if currentModule == "reader", id != "reader" {
            readerView.flushPosition()
        }
        currentModule = id

        libraryView.isHidden = (id != "library")
        readerView.isHidden = (id != "reader")
        notesView.isHidden = (id != "notes")
        reviewView.isHidden = (id != "review")
        webContainer.isHidden = (id != "app")

        switch module.kind {
        case .library:
            break

        case .reader:
            showReader()

        case .notes:
            notesView.show(notes: LearningStore.shared.allNotes)

        case .review:
            refreshReview()

        case .app:
            for (appId, webView) in webViews {
                webView.isHidden = (appId != current.id)
            }
            loadIfNeeded(current)

        case .planned:
            break
        }

        sidebar.setSelectedModule(id: id)
        updateWindowTitle()
        UserDefaults.standard.set(id, forKey: lastModuleKey)
    }

    /// The reader shows whatever was last open; if there is nothing yet, it
    /// says so rather than sitting on a blank page.
    private func showReader() {
        guard let id = LearningStore.shared.lastReadDocumentId,
              let document = LibraryStore.shared.document(id: id) else {
            readerView.showUnavailable(message: "Pick a document from the Library to read its briefing.")
            return
        }
        renderBriefing(for: document, at: openChapter)
        openChapter = nil
    }

    /// Put a document's briefing into the reader.
    ///
    /// `chapter` asks for a particular chapter — a note links to the one it
    /// was taken from. Without it the reader goes back to where they left
    /// off, which is the point of remembering a place.
    private func renderBriefing(for document: LibraryDocument, at chapter: Int? = nil) {
        openDocumentId = document.id

        let position = chapter.map {
            ReadingPosition(chapter: $0, scroll: 0, updatedAt: Date())
        } ?? LearningStore.shared.position(for: document.id)

        // Already fetched once — render it straight away.
        if let briefing = BriefingStore.shared.briefing(documentId: document.id) {
            readerView.show(briefing: briefing, restoring: position)
            return
        }

        readerView.showLoading(title: document.title)
        BriefingStore.shared.load(documentId: document.id,
                                  spec: specs.first(where: { $0.supportsLibrary })) { [weak self] briefing in
            guard let self else { return }
            guard let briefing else {
                self.readerView.showUnavailable(
                    message: "The briefing for “\(document.title)” is not ready yet. "
                           + "It appears as soon as the synthesis finishes."
                )
                return
            }
            self.readerView.show(briefing: briefing, restoring: position)
        }
    }

    private func updateWindowTitle() {
        switch currentModule {
        case "library":
            window.title = "Sloth Suite"
            window.subtitle = "\(LibraryStore.shared.documents.count) documents"
        case "reader":
            window.title = "Sloth Suite — Reader"
            window.subtitle = currentReaderTitle
        case "notes":
            window.title = "Sloth Suite — Notes"
            window.subtitle = "\(LearningStore.shared.allNotes.count) notes"
        case "review":
            window.title = "Sloth Suite — Review"
            window.subtitle = "\(LearningStore.shared.dueCount) due"
        case "app":
            window.title = "Sloth Suite — \(current.title)"
            window.subtitle = current.tagline
        default:
            window.title = "Sloth Suite"
            window.subtitle = ""
        }
    }

    /// The title of the document open in the reader, if there is one.
    private var currentReaderTitle: String {
        guard let id = openDocumentId,
              let document = LibraryStore.shared.document(id: id) else { return "Nothing open" }
        return document.title
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
        fileMenu.addItem(withTitle: "Add a Document…", action: #selector(addDocument), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "New Note…", action: #selector(newNote), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Continue Reading…", action: #selector(continueReadingAction), keyEquivalent: "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Export as Separate Files…", action: #selector(exportFiles), keyEquivalent: "e")
        fileMenu.addItem(withTitle: "Export Notes…", action: #selector(exportNotes), keyEquivalent: "E")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "All Audio…", action: #selector(speakOpenDocument), keyEquivalent: "s")
        fileMenu.addItem(withTitle: "Audio and Chapters…", action: #selector(openAudioWindow), keyEquivalent: "")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        for (index, module) in SuiteModules.all.enumerated() where module.isAvailable {
            let item = viewMenu.addItem(withTitle: module.title,
                                       action: #selector(selectModuleFromMenu(_:)),
                                       keyEquivalent: index < 9 ? "\(index + 1)" : "")
            item.representedObject = module.id
            item.keyEquivalentModifierMask = [.command]
        }
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Command Palette…", action: #selector(showCommandPalette), keyEquivalent: "k")
        viewMenu.addItem(withTitle: "Find in Briefing…", action: #selector(findInBriefing), keyEquivalent: "f")
        viewMenu.addItem(withTitle: "Focus Library Search", action: #selector(focusLibrarySearch), keyEquivalent: "l")
        viewMenu.addItem(withTitle: "Keyboard Shortcuts…", action: #selector(showShortcutSheet), keyEquivalent: "")
        viewMenu.addItem(.separator())
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

    @objc private func selectModuleFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        showModule(id)
    }

    // MARK: - Selection

    private func select(_ spec: AppSpec) {
        current = spec
        for (id, webView) in webViews {
            webView.isHidden = (id != spec.id)
        }
        updateWindowTitle()
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

    // MARK: - Stack supervision

    /// Start the stack only for the services that are genuinely down.
    private func startStackIfNeeded() {
        if !stackManager.scriptAvailable {
            // The configured path may simply be stale — a moved project, a
            // different account. Try the well-known location before telling
            // the user to go and edit a config file.
            if stackManager.recoverScriptPath() {
                Log.shared.write("recovered the stack script path to \(stackManager.scriptURL.path)")
                config.stackScript = stackManager.scriptURL.path
                config.save()
            } else {
                Log.shared.write("stack script missing at \(stackManager.scriptURL.path)")
                sidebar.setStatus("Stack script not found")
                presentError(title: "Stack script not found",
                             message: "Expected the stack script at:\n\(stackManager.scriptURL.path)\n\n"
                                + "It was looked for in your Projects folder too. Set the path in:\n\(SuiteConfig.configFileURL.path)")
                return
            }
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
    private func serviceWentDown(_ appId: String) {
        guard let spec = config.app(id: appId),
              let service = config.service(id: spec.service) else { return }

        Log.shared.write("service \(service.id) went down — restarting it")

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            self.stackManager.restart(service: service) { up in
                DispatchQueue.main.async {
                    self.sidebar.setStatus(up ? "Stack running" : "Stack degraded")
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
        let all = health.allStatuses
        let allUp = !all.isEmpty && specs.allSatisfy { all[$0.id]?.ok == true }
        let model = specs.compactMap { all[$0.id]?.ok == true ? all[$0.id]?.model : nil }.first ?? "offline"

        var parts: [String] = []
        parts.append(allUp ? "Stack running" : "Stack starting")
        parts.append(model)
        if let web = webAccessEnabled { parts.append(web ? "Web on" : "Web off") }
        sidebar.setStatus(parts.joined(separator: " · "))
    }

    // MARK: - Actions

    private func handle(_ action: SidebarView.SidebarAction) {
        switch action {
        case .addDocument: addDocument()
        case .newNote: startNote(forDocumentId: "", title: "")
        case .continueReading: continueReading()
        case .exportFiles: performExport(document: nil)
        case .speak: speakSummary(for: nil)
        case .allAudio: speakOpenDocument()
        case .audioChapters: openAudioWindow()
        case .restartStack: restartStack()
        case .reloadPage: reloadPage()
        case .showLogs: showLogs()
        case .copyDiagnostics: copyDiagnostics()
        case .toggleWeb: toggleWebAccess()
        case .setProvider(let provider): setProvider(provider)
        case .openDocument(let id): openDocument(id: id)
        case .deleteDocument(let id, let title): confirmDelete(id: id, title: title)
        }
    }

    @objc private func addDocument() {
        guard let spec = specs.first(where: { $0.supportsLibrary }) else {
            presentError(title: "No library", message: "This build has no app that accepts documents.")
            return
        }

        // Switch to the app first, then trigger its own file input so the
        // real upload handler runs rather than a side-loaded request.
        showModule("app")
        if current.id != spec.id {
            select(spec)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.triggerAddBook()
        }
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

    /// A file dropped on the window goes straight to the app.
    private func importDroppedFile(_ url: URL) {
        guard let spec = specs.first(where: { $0.supportsLibrary }) else { return }
        Log.shared.write("dropped \(url.lastPathComponent)")
        showModule("app")
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
                    self.library.refresh(spec: spec)
                } else {
                    let detail = (data.flatMap { JSONTools.dictionary(from: $0)?["detail"] as? String }) ?? "HTTP \(code)"
                    self.presentError(title: "Could not import that file", message: detail)
                }
            }
        }.resume()
    }

    // MARK: - Export as separate files

    /// Menu and toolbar entry point.
    @objc private func exportFiles() {
        performExport(document: nil)
    }

    /// Write every note out as a Markdown file.
    ///
    /// The notes are the user's own writing, so there has to be a way to
    /// get them out of the app and into whatever they use next.
    @objc private func exportNotes() {
        let notes = LearningStore.shared.allNotes
        guard !notes.isEmpty else {
            presentError(title: "There are no notes to export",
                         message: "Write a note while you read, and it will appear here.")
            return
        }

        Exporter.writeNotes(notes) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let url):
                    // Shown in the Finder, the way the other export is.
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                case .failure(let error):
                    // The user closed the panel. That is not a failure.
                    if let exportError = error as? Exporter.ExportError, case .noFiles = exportError {
                        return
                    }
                    self?.presentError(title: "Could not export the notes",
                                       message: error.localizedDescription)
                }
            }
        }
    }

    private func performExport(document: LibraryDocument?) {
        guard let spec = specs.first(where: { $0.supportsLibrary }) else { return }

        // A specific document — from the reader, or from a card's menu — is
        // exported straight from the backend. The page's own view is only
        // used when nothing specific was asked for, because the page may be
        // showing a different document from the one the user means.
        let target = document
            ?? openDocumentId.flatMap { LibraryStore.shared.document(id: $0) }

        if let target {
            fetchBundleFromBackend(spec: spec, document: target)
            return
        }

        // Prefer the page's own view of the document, so the export matches
        // what is on screen; fall back to the backend's bundle endpoint.
        guard let bridge = bridges[spec.id], let webView = webViews[spec.id] else {
            fetchBundleFromBackend(spec: spec, document: nil)
            return
        }

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
                    let title = (dict["title"] as? String) ?? document?.title ?? "Briefing"
                    self?.writeExport(mapped, title: title)
                    return
                }
                self?.fetchBundleFromBackend(spec: spec, document: document)
            case .failure(_), .unsupported(_):
                self?.fetchBundleFromBackend(spec: spec, document: document)
            }
        }
    }

    private func fetchBundleFromBackend(spec: AppSpec, document: LibraryDocument?) {
        guard let base = spec.apiBase else { return }

        let makeRequest: (String) -> URLRequest = { path in
            var request = URLRequest(url: base.appendingPathComponent(path))
            request.timeoutInterval = 15
            return request
        }

        URLSession.shared.dataTask(with: makeRequest("/api/documents")) { [weak self] data, _, error in
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

            let docId = document?.id
                ?? documents.first(where: { ($0["status"] as? String) == "completed" })?["doc_id"] as? String
            guard let docId else {
                DispatchQueue.main.async {
                    self.presentError(title: "Nothing to export",
                                      message: "There is no completed briefing to export yet.")
                }
                return
            }

            URLSession.shared.dataTask(with: makeRequest("/api/documents/\(docId)/bundle")) { bundleData, _, bundleError in
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

    /// Speak arbitrary text with the Mac's own voice.
    ///
    /// Used by the reader, which speaks a chapter or the whole briefing, and
    /// by anything else that has text rather than a stored audio script.
    private func speakText(_ text: String, title: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            presentError(title: "Nothing to read aloud",
                         message: "“\(title)” has no text to speak.")
            return
        }

        MacServices.shared.status { [weak self] status in
            guard let self else { return }
            guard status.reachable, status.speech else {
                self.presentError(title: "The Mac voice is not available",
                                  message: "Start Sloth Suite from the Applications folder so the Mac service can run.")
                return
            }

            DispatchQueue.main.async {
                self.setDockBadge("🔊")
                AudioPlayer.shared.speak(trimmed, label: title)
            }
        }
    }

    /// Read every chapter of the open briefing, one after another.
    private func speakEverything(_ briefing: Briefing) {
        let texts = briefing.chapters.map { chapter in
            chapter.audioScript.isEmpty ? chapter.spokenText : chapter.audioScript
        }
        let labels = briefing.chapters.enumerated().map { "Chapter \($0.offset + 1)" }

        guard !texts.isEmpty else {
            speakText(briefing.plainText, title: briefing.title)
            return
        }

        setDockBadge("🔊")
        AudioPlayer.shared.speakAll(texts, labels: labels)
    }

    /// Speak a briefing using the Mac's own voice.
    private func speakSummary(for document: LibraryDocument?) {
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
                      let documents = json["documents"] as? [[String: Any]] else {
                    DispatchQueue.main.async {
                        self.presentError(title: "Nothing to speak",
                                          message: "The library could not be read.")
                    }
                    return
                }

                let docId = document?.id
                    ?? documents.first(where: { ($0["status"] as? String) == "completed" })?["doc_id"] as? String
                guard let docId else {
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

                    guard !script.isEmpty else {
                        DispatchQueue.main.async {
                            self.presentError(title: "Nothing to speak",
                                              message: "This briefing has no audio script.")
                        }
                        return
                    }

                    DispatchQueue.main.async {
                        // The queue plays the chapters one after another
                        // rather than reading them all at once.
                        let labels = script.enumerated().map { "Chapter \($0.offset + 1)" }
                        self.setDockBadge("🔊")
                        AudioPlayer.shared.speakAll(script, labels: labels)
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
                self.sidebar.setProvider(provider == "mac" ? "Mac model" : "Ollama")
            }
        }.resume()

        MacServices.shared.status { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                self.macModelAvailable = status.reachable && status.foundationModels == "available"
                self.sidebar.setProvider(self.aiProvider == "mac" ? "Mac model" : "Ollama")
            }
        }
    }

    // MARK: - Web access

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
                self.applyHealth(id: spec.id, status: self.health.status(for: spec.id))
            }
        }.resume()
    }

    // MARK: - Library

    private func openDocument(_ document: LibraryDocument) {
        openDocument(id: document.id)
    }

    /// Open a document in the native reader.
    ///
    /// The briefing is fetched from the backend and rendered natively, so the
    /// reader works even when the wrapped app is not running.
    ///
    /// `chapter` asks for a particular chapter, which is how a note links
    /// back to the place it was taken from.
    private func openDocument(id: String, chapter: Int? = nil) {
        guard LibraryStore.shared.document(id: id) != nil else { return }

        openDocumentId = id
        openChapter = chapter
        // The reader picks up whatever was last opened, so the order matters:
        // remember it first, then switch.
        LearningStore.shared.markReading(documentId: id)
        showModule("reader")
        updateWindowTitle()
    }

    /// Open a document in the wrapped web app instead of the native reader.
    private func openInApp(documentId: String) {
        guard let spec = specs.first(where: { $0.supportsLibrary }) else { return }
        showModule("app")
        if current.id != spec.id { select(spec) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self,
                  let bridge = self.bridges[spec.id],
                  let webView = self.webViews[spec.id] else { return }
            bridge.perform("openDocument", payload: ["id": documentId], in: webView) { result in
                if case .failure(let message) = result {
                    self.presentError(title: "Could not open that document", message: message)
                }
            }
        }
    }

    /// Resume the last document that was being read.
    private func continueReading() {
        guard let id = LearningStore.shared.lastReadDocumentId else {
            presentError(title: "Nothing to continue",
                         message: "You have not opened a document yet.")
            return
        }
        openDocument(id: id)
    }

    // MARK: - Notes

    private func startNote(for document: LibraryDocument) {
        startNote(forDocumentId: document.id, title: document.title)
    }

    /// Create a note and open it in the notes module.
    ///
    /// A note made from the reader remembers the chapter it was taken from,
    /// so it can be found again in the book it came from.
    private func startNote(forDocumentId id: String, title: String, chapter: Int = 0) {
        let note = LearningStore.shared.addNote(documentId: id, documentTitle: title, chapter: chapter)
        showModule("notes")
        notesView.show(notes: LearningStore.shared.allNotes)
        notesView.select(noteId: note.id)
    }

    /// Fill the review desk with the notes that are due.
    private func refreshReview() {
        let due = LearningStore.shared.dueNotes()
        let upcoming = LearningStore.shared.notesNotDue()
        let total = LearningStore.shared.allNotes.count
        reviewView.show(due: due, total: total, upcoming: upcoming.count)
    }

    private func filterNotes(_ query: String) {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = LearningStore.shared.allNotes
        guard !needle.isEmpty else {
            notesView.show(notes: all)
            return
        }
        notesView.show(notes: all.filter { note in
            "\(note.documentTitle) \(note.body)".lowercased().contains(needle)
        })
    }

    private func confirmDeleteNote(_ note: StudyNote) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete this note?"
        alert.informativeText = "The note is removed from this machine. This cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        LearningStore.shared.deleteNote(id: note.id)
        notesView.show(notes: LearningStore.shared.allNotes)
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
                    self.library.refresh(spec: spec)
                } else {
                    self.presentError(title: "Could not remove that document",
                                      message: "The backend answered HTTP \(code).")
                }
            }
        }.resume()
    }

    // MARK: - Commands

    @objc private func newNote() {
        startNote(forDocumentId: "", title: "")
    }

    @objc private func continueReadingAction() {
        continueReading()
    }

    /// Speak whatever is open in the reader.
    @objc private func speakOpenDocument() {
        guard let id = openDocumentId,
              let briefing = BriefingStore.shared.briefing(documentId: id) else {
            speakSummary(for: nil)
            return
        }
        speakEverything(briefing)
    }

    /// Open the pop-out window with every chapter and its spoken script.
    @objc private func openAudioWindow() {
        guard let id = openDocumentId,
              let briefing = BriefingStore.shared.briefing(documentId: id) else {
            presentError(title: "No document open",
                         message: "Open a document from the Library first.")
            return
        }
        AudioWindowController.shared.show(briefing: briefing)
    }

    /// Open the reader's own find bar.
    @objc private func findInBriefing() {
        showModule("reader")
        readerView.focusFindBar()
    }

    /// Put the cursor in the library's search field.
    @objc private func focusLibrarySearch() {
        showModule("library")
        libraryView.focusSearch()
    }

    @objc private func restartStack() {
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
                    self.library.refresh(spec: self.specs.first(where: { $0.supportsLibrary }))
                }
            }
        }
    }

    @objc private func reloadPage() {
        reloadActivePage()
        library.refresh(spec: specs.first(where: { $0.supportsLibrary }))
    }

    @objc private func showLogs() {
        let directory = config.resolvedLogDirectory
        PathTools.ensureDirectory(directory)
        NSWorkspace.shared.open(directory)
    }

    /// Copy a diagnostics bundle to the clipboard.
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

        for module in SuiteModules.all where module.isAvailable {
            let subtitle: String
            switch module.kind {
            case .library: subtitle = "Your documents"
            case .reader: subtitle = "Read a briefing"
            case .notes: subtitle = "Notes you have written"
            case .review: subtitle = "Remember your notes"
            case .app: subtitle = current.tagline
            case .planned: subtitle = ""
            }
            commands.append(CommandPalette.Command(
                title: "Go to \(module.title)",
                subtitle: subtitle
            ) { [weak self] in
                self?.showModule(module.id)
            })
        }

        commands.append(CommandPalette.Command(title: "Add a document…") { [weak self] in
            self?.addDocument()
        })
        commands.append(CommandPalette.Command(title: "New note…") { [weak self] in
            self?.startNote(forDocumentId: "", title: "")
        })
        commands.append(CommandPalette.Command(title: "Continue reading…") { [weak self] in
            self?.continueReading()
        })
        commands.append(CommandPalette.Command(title: "Export as separate files…") { [weak self] in
            self?.performExport(document: nil)
        })
        commands.append(CommandPalette.Command(title: "Read everything aloud") { [weak self] in
            self?.speakOpenDocument()
        })
        commands.append(CommandPalette.Command(title: "Audio and chapters…") { [weak self] in
            self?.openAudioWindow()
        })
        commands.append(CommandPalette.Command(title: "Speak the summary with the Mac") { [weak self] in
            self?.speakSummary(for: nil)
        })
        commands.append(CommandPalette.Command(title: "Restart the stack") { [weak self] in
            self?.restartStack()
        })
        commands.append(CommandPalette.Command(title: "Reload") { [weak self] in
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
        commands.append(CommandPalette.Command(title: "Keyboard shortcuts") { [weak self] in
            self?.showShortcutSheet()
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

        // The provider is asked again on every keystroke, so the palette
        // searches the library and the notes as they are right now.
        CommandPalette.show(commands: commands) { [weak self] query in
            guard let self else { return commands }
            return commands + self.searchResults(for: query)
        }
    }

    /// Documents and notes that match the palette's query.
    private func searchResults(for query: String) -> [CommandPalette.Command] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }

        var results: [CommandPalette.Command] = []

        for document in LibraryStore.shared.documents {
            let haystack = "\(document.title) \(document.author) \(document.filename)".lowercased()
            guard haystack.contains(needle) else { continue }
            results.append(CommandPalette.Command(
                title: document.title,
                subtitle: document.author.isEmpty ? document.filename : document.author
            ) { [weak self] in
                self?.openDocument(id: document.id)
            })
        }

        for note in LearningStore.shared.allNotes {
            let haystack = "\(note.documentTitle) \(note.body)".lowercased()
            guard haystack.contains(needle) else { continue }
            results.append(CommandPalette.Command(
                title: note.preview.isEmpty ? "(empty note)" : note.preview,
                subtitle: note.documentTitle.isEmpty ? "Note" : "Note — \(note.documentTitle)"
            ) { [weak self] in
                self?.openNote(note)
            })
        }

        return results
    }

    /// Show a note in the notes module.
    private func openNote(_ note: StudyNote) {
        showModule("notes")
        notesView.show(notes: LearningStore.shared.allNotes)
        notesView.select(noteId: note.id)
    }

    /// A short sheet of the keyboard shortcuts.
    @objc private func showShortcutSheet() {
        let rows: [(String, String)] = [
            ("⌘K", "Open the command palette"),
            ("⌘1 – ⌘5", "Switch between Library, Reader, Notes, Review and App"),
            ("⌘L", "Focus the library search"),
            ("⌘F", "Find in the open briefing"),
            ("⌘N", "New note"),
            ("⌘O", "Add a document"),
            ("⌘E", "Export as separate files"),
            ("⌘S", "Speak the open briefing"),
            ("⌘\\", "Show or hide the sidebar"),
            ("⌘R", "Reload the app"),
            ("⌘D", "Copy diagnostics")
        ]

        let alert = NSAlert()
        alert.messageText = "Keyboard shortcuts"
        alert.informativeText = rows.map { "\($0.0)\t\($0.1)" }.joined(separator: "\n")
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Done")
        alert.runModal()
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
            } else {
                try SMAppService.mainApp.register()
                sender.state = .on
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

        guard name == "synthesisComplete" || name == "planReady" else { return }
        let title = (data["title"] as? String) ?? "Your document"
        notify(title: title, body: "Ready in the app.")
        library.refresh(spec: specs.first(where: { $0.supportsLibrary }))
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
    var healthForTest: HealthMonitor { health }
    var stackForTest: StackManager { stackManager }
    var configForTest: SuiteConfig { config }
    var currentSpecForTest: AppSpec { current }
    var notesViewForTest: NotesView { notesView }
    var readerViewForTest: ReaderView { readerView }

    func webViewForTest(_ id: String) -> WKWebView? { webViews[id] }
    func bridgeForTest(_ id: String) -> Bridge? { bridges[id] }

    func selectForTest(_ spec: AppSpec) { select(spec) }
    func showModuleForTest(_ id: String) { showModule(id) }
    func currentModuleForTest() -> String { currentModule }

    /// Trigger the reader's own file picker (used by the self-test).
    func triggerAddBookForTest() { triggerAddBook() }

    /// Evaluate JavaScript in the active page, reporting back on the main thread.
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
        Log.shared.write("loaded \(current.id) — \(webView.title ?? "(untitled)")")
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

// MARK: - Toolbar

extension SuiteController: NSToolbarDelegate {
    private static let toolbarItems: [(String, String, String)] = [
        ("add", "plus", "Add Document"),
        ("note", "note.text.badge.plus", "New Note"),
        ("audio", "speaker.wave.3", "All Audio"),
        ("chapters", "list.bullet.rectangle", "Audio and Chapters"),
        ("export", "square.and.arrow.up", "Export as Separate Files"),
        ("speak", "waveform", "Speak the Briefing"),
        ("reload", "arrow.clockwise", "Reload"),
        ("restart", "arrow.triangle.2.circlepath", "Restart Stack"),
        ("logs", "doc.text.magnifyingglass", "Show Logs")
    ]

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.toolbarItems.map { NSToolbarItem.Identifier($0.0) }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let entry = Self.toolbarItems.first(where: { $0.0 == identifier.rawValue }) else { return nil }

        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = entry.2
        item.toolTip = entry.2
        item.image = NSImage(systemSymbolName: entry.1, accessibilityDescription: entry.2)
        item.target = self
        item.action = #selector(toolbarAction(_:))
        item.tag = Self.toolbarItems.firstIndex(where: { $0.0 == identifier.rawValue }) ?? 0
        return item
    }

    @objc private func toolbarAction(_ sender: NSToolbarItem) {
        switch sender.tag {
        case 0: addDocument()
        case 1: startNote(forDocumentId: "", title: "")
        case 2: speakOpenDocument()
        case 3: openAudioWindow()
        case 4: performExport(document: nil)
        case 5: speakOpenDocument()
        case 6: reloadPage()
        case 7: restartStack()
        case 8: showLogs()
        default: break
        }
    }
}
