import Cocoa
import Foundation

// MARK: - Layout helper

/// Auto Layout only moves the views it owns, and a view belongs to Auto
/// Layout once it has given up its autoresizing mask. Labels, buttons and
/// image views keep the mask by default, so every view we place with a
/// constraint has to hand it over explicitly.
private func handOverToAutoLayout(_ views: NSView...) {
    for view in views {
        view.translatesAutoresizingMaskIntoConstraints = false
    }
}

// MARK: - The notes module

/// The notes desk: a list of notes on the left, the note itself on the right.
///
/// Notes are what turn a library into a learning desk — the books are what
/// you read, the notes are what you keep. The module is deliberately plain
/// AppKit: a table on the left, a text view on the right, and nothing the
/// user has to learn.
///
/// The view owns the layout and the editor. Saving and deleting notes
/// belongs to the controller, which talks to us through the callbacks
/// below. The one thing we do ourselves is make a note when the user asks
/// for one: the editor needs an id to save into, and the controller may
/// have made that note for us instead.
final class NotesView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate, NSSearchFieldDelegate {

    // MARK: Callbacks

    /// The user picked a different note in the list.
    var onSelectNote: ((StudyNote) -> Void)?
    /// The user deleted a note.
    var onDeleteNote: ((StudyNote) -> Void)?
    /// The user edited the body of a note. Arguments: (noteId, newBody).
    var onChangeNoteBody: ((String, String) -> Void)?
    /// The user asked for a brand new, empty note.
    var onCreateNote: (() -> Void)?
    /// The user wants to open the document a note belongs to.
    var onOpenDocument: ((StudyNote) -> Void)?
    /// The user wants to search notes. Pass the raw query text.
    var onSearch: ((String) -> Void)?

    // MARK: Subviews

    private let listPane = NSView()
    private let divider = NSView()
    private let editorPane = NSView()

    private let titleLabel = NSTextField(labelWithString: "Notes")
    private let countLabel = NSTextField(labelWithString: "")
    private let newNoteButton = NSButton(title: "New Note", target: nil, action: nil)
    private let searchField = NSSearchField()
    private let listScrollView = NSScrollView()
    private let tableView = NSTableView()
    private let listEmptyState = NSStackView()

    private let editorTitleLabel = NSTextField(labelWithString: "")
    private let editorSubtitleLabel = NSTextField(labelWithString: "")
    private let openDocumentButton = NSButton(title: "Open document", target: nil, action: nil)
    private let editorScrollView = NSScrollView()
    private let textView = NSTextView()
    private let editorPlaceholder = NSStackView()

    // MARK: State

    /// The notes currently on screen, in the order the controller gave them.
    private var notes: [StudyNote] = []

    /// The note the editor is writing into, if any.
    private var currentNoteId: String?

    /// When the user last asked for a brand-new note, and which notes already
    /// existed at that moment.
    ///
    /// The controller may answer that request by making the note itself; this
    /// is how we recognise a note it has just made.
    ///
    /// The list of ids matters as much as the date. Without it the view adopts
    /// *any* empty note it can find, so an old note that was never written
    /// in swallows the request: the user presses "New Note", the same empty
    /// note opens again, and it looks like the button does nothing.
    private var newNoteRequest: (asked: Date, existing: Set<String>)?

    /// The body the store currently holds for `currentNoteId`.
    ///
    /// Everything that changes the text of the editor goes through here first,
    /// so a programmatic load never looks like the user typing.
    private var lastKnownBody = ""

    /// The debounced auto-save.
    ///
    /// The delay runs on a background queue, not on the main run loop. The
    /// main thread can be busy for a long time — fetching a briefing,
    /// uploading a document — and a timer that lives there waits for it. A
    /// note the user has already typed is a note that should be on disk,
    /// whatever else the app is doing.
    private var saveWork: DispatchWorkItem?

    /// Set while the table selection is changed by us, so that the change
    /// notification does not look like the user clicking a row.
    private var isUpdatingSelection = false

    /// How long the editor waits for a pause in typing before it saves.
    private static let saveDebounce: TimeInterval = 0.4

    // MARK: - Build

    init() {

        // Auto Layout positions these, so the autoresizing mask must not
        // fight it — a view with the mask on keeps its old frame and is
        // never moved by its constraints.
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        newNoteButton.translatesAutoresizingMaskIntoConstraints = false
        editorTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        editorSubtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        openDocumentButton.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        buildListPane()
        buildEditorPane()
        buildLayout()

        updateHeader()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        // The work item holds the run loop, not us, but leaving it running
        // would keep firing into a view that no longer exists.
        saveWork?.cancel()
    }

    private func buildListPane() {
        listPane.wantsLayer = true
        listPane.layer?.backgroundColor = resolvedCGColor(NSColor.controlBackgroundColor)
        listPane.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        handOverToAutoLayout(titleLabel, countLabel)

        newNoteButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New note")
        newNoteButton.imagePosition = .imageLeading
        newNoteButton.bezelStyle = .rounded
        newNoteButton.controlSize = .small
        newNoteButton.font = .systemFont(ofSize: 11)
        newNoteButton.target = self
        newNoteButton.action = #selector(newNotePressed)
        newNoteButton.toolTip = "Start a new note"
        newNoteButton.setAccessibilityLabel("New note")
        // The notes module's own colour, on its one action.
        newNoteButton.contentTintColor = Palette.green
        newNoteButton.setColoredTitle("New Note", color: Palette.green,
                                      font: .systemFont(ofSize: 11))
        handOverToAutoLayout(newNoteButton)

        searchField.placeholderString = "Search notes"
        searchField.font = .systemFont(ofSize: 12)
        searchField.controlSize = .small
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = false
        searchField.setAccessibilityLabel("Search notes")
        searchField.translatesAutoresizingMaskIntoConstraints = false

        // The table recycles its rows, so a library of a thousand notes costs
        // exactly as much as a library of ten.
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("note"))
        column.width = 280
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 50
        tableView.style = .plain
        // The selection is drawn by the row itself, so that it looks like a
        // Finder sidebar row instead of a slab of solid colour.
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(tableRowActivated)
        tableView.translatesAutoresizingMaskIntoConstraints = false

        listScrollView.documentView = tableView
        listScrollView.hasVerticalScroller = true
        listScrollView.drawsBackground = false
        listScrollView.borderType = .noBorder
        listScrollView.translatesAutoresizingMaskIntoConstraints = false

        // Empty state
        listEmptyState.orientation = .vertical
        listEmptyState.alignment = .centerX
        listEmptyState.spacing = 6
        listEmptyState.translatesAutoresizingMaskIntoConstraints = false

        let emptyIcon = NSImageView()
        emptyIcon.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: nil)
        emptyIcon.contentTintColor = Palette.accent.withAlphaComponent(0.45)
        emptyIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 32, weight: .light)
        emptyIcon.translatesAutoresizingMaskIntoConstraints = false

        let emptyHint = NSTextField(wrappingLabelWithString: "No notes yet — read something and jot down what matters.")
        emptyHint.translatesAutoresizingMaskIntoConstraints = false
        emptyHint.font = .systemFont(ofSize: 12)
        emptyHint.textColor = .tertiaryLabelColor
        emptyHint.alignment = .center
        handOverToAutoLayout(emptyHint)

        listEmptyState.addArrangedSubview(emptyIcon)
        listEmptyState.addArrangedSubview(emptyHint)

        // Header
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titleLabel)
        header.addSubview(countLabel)
        header.addSubview(newNoteButton)

        titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor).isActive = true
        titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor).isActive = true

        countLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8).isActive = true
        countLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor).isActive = true

        newNoteButton.trailingAnchor.constraint(equalTo: header.trailingAnchor).isActive = true
        newNoteButton.centerYAnchor.constraint(equalTo: header.centerYAnchor).isActive = true

        header.heightAnchor.constraint(equalToConstant: 24).isActive = true

        listPane.addSubview(header)
        listPane.addSubview(searchField)
        listPane.addSubview(listScrollView)
        listPane.addSubview(listEmptyState)

        header.leadingAnchor.constraint(equalTo: listPane.leadingAnchor, constant: 14).isActive = true
        header.trailingAnchor.constraint(equalTo: listPane.trailingAnchor, constant: -14).isActive = true
        header.topAnchor.constraint(equalTo: listPane.topAnchor, constant: 14).isActive = true

        searchField.leadingAnchor.constraint(equalTo: listPane.leadingAnchor, constant: 12).isActive = true
        searchField.trailingAnchor.constraint(equalTo: listPane.trailingAnchor, constant: -12).isActive = true
        searchField.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10).isActive = true

        listScrollView.leadingAnchor.constraint(equalTo: listPane.leadingAnchor).isActive = true
        listScrollView.trailingAnchor.constraint(equalTo: listPane.trailingAnchor).isActive = true
        listScrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8).isActive = true
        listScrollView.bottomAnchor.constraint(equalTo: listPane.bottomAnchor).isActive = true

        listEmptyState.centerXAnchor.constraint(equalTo: listScrollView.centerXAnchor).isActive = true
        listEmptyState.centerYAnchor.constraint(equalTo: listScrollView.centerYAnchor).isActive = true
        listEmptyState.widthAnchor.constraint(lessThanOrEqualTo: listPane.widthAnchor, constant: -40).isActive = true
        emptyHint.widthAnchor.constraint(equalToConstant: 220).isActive = true
    }

    private func buildEditorPane() {
        editorPane.wantsLayer = true
        editorPane.layer?.backgroundColor = resolvedCGColor(NSColor.textBackgroundColor)
        editorPane.translatesAutoresizingMaskIntoConstraints = false

        editorTitleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        editorTitleLabel.textColor = .labelColor
        editorTitleLabel.lineBreakMode = .byTruncatingTail

        editorSubtitleLabel.font = .systemFont(ofSize: 11)
        editorSubtitleLabel.textColor = .secondaryLabelColor
        handOverToAutoLayout(editorTitleLabel, editorSubtitleLabel)

        openDocumentButton.image = NSImage(systemSymbolName: "book", accessibilityDescription: "Open document")
        openDocumentButton.imagePosition = .imageLeading
        openDocumentButton.bezelStyle = .rounded
        openDocumentButton.controlSize = .small
        openDocumentButton.font = .systemFont(ofSize: 11)
        openDocumentButton.target = self
        openDocumentButton.action = #selector(openDocumentPressed)
        openDocumentButton.toolTip = "Open the document this note belongs to"
        openDocumentButton.setAccessibilityLabel("Open document")
        openDocumentButton.contentTintColor = Palette.blue
        openDocumentButton.setColoredTitle("Open document", color: Palette.blue,
                                           font: .systemFont(ofSize: 11))
        handOverToAutoLayout(openDocumentButton)

        // A plain text editor: the note is the user's own words, so it stays
        // plain text and stays readable.
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        // The padding around the text is 18 points top and bottom and 20
        // points left and right. AppKit's text view takes one symmetric
        // inset, so the two values become one width and one height.
        textView.textContainerInset = NSSize(width: 20, height: 18)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = self
        // The scroll view owns the frame of its document view, so the text
        // view keeps its autoresizing mask.

        editorScrollView.documentView = textView
        editorScrollView.hasVerticalScroller = true
        editorScrollView.hasHorizontalScroller = false
        editorScrollView.autohidesScrollers = true
        editorScrollView.drawsBackground = false
        editorScrollView.borderType = .noBorder
        editorScrollView.translatesAutoresizingMaskIntoConstraints = false

        // Placeholder for "no note open" — a calm page, not an empty editor
        // that looks like it is asking for text.
        editorPlaceholder.orientation = .vertical
        editorPlaceholder.alignment = .centerX
        editorPlaceholder.spacing = 6
        editorPlaceholder.translatesAutoresizingMaskIntoConstraints = false

        let placeholderIcon = NSImageView()
        placeholderIcon.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)
        placeholderIcon.contentTintColor = Palette.accent.withAlphaComponent(0.45)
        placeholderIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 30, weight: .light)
        placeholderIcon.translatesAutoresizingMaskIntoConstraints = false

        let placeholderTitle = NSTextField(labelWithString: "No note open")
        placeholderTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        placeholderTitle.textColor = .secondaryLabelColor

        let placeholderHint = NSTextField(wrappingLabelWithString: "Pick a note on the left, or start a new one.")
        placeholderHint.translatesAutoresizingMaskIntoConstraints = false
        placeholderHint.font = .systemFont(ofSize: 12)
        placeholderHint.textColor = .tertiaryLabelColor
        placeholderHint.alignment = .center
        handOverToAutoLayout(placeholderTitle, placeholderHint)

        editorPlaceholder.addArrangedSubview(placeholderIcon)
        editorPlaceholder.addArrangedSubview(placeholderTitle)
        editorPlaceholder.addArrangedSubview(placeholderHint)

        // Header
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(editorTitleLabel)
        header.addSubview(editorSubtitleLabel)
        header.addSubview(openDocumentButton)

        editorTitleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor).isActive = true
        editorTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: openDocumentButton.leadingAnchor, constant: -12).isActive = true
        editorTitleLabel.topAnchor.constraint(equalTo: header.topAnchor).isActive = true

        openDocumentButton.trailingAnchor.constraint(equalTo: header.trailingAnchor).isActive = true
        openDocumentButton.centerYAnchor.constraint(equalTo: editorTitleLabel.centerYAnchor).isActive = true

        editorSubtitleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor).isActive = true
        editorSubtitleLabel.topAnchor.constraint(equalTo: editorTitleLabel.bottomAnchor, constant: 2).isActive = true
        editorSubtitleLabel.bottomAnchor.constraint(equalTo: header.bottomAnchor).isActive = true

        editorPane.addSubview(header)
        editorPane.addSubview(editorScrollView)
        editorPane.addSubview(editorPlaceholder)

        header.leadingAnchor.constraint(equalTo: editorPane.leadingAnchor, constant: 22).isActive = true
        header.trailingAnchor.constraint(equalTo: editorPane.trailingAnchor, constant: -22).isActive = true
        header.topAnchor.constraint(equalTo: editorPane.topAnchor, constant: 16).isActive = true

        editorScrollView.leadingAnchor.constraint(equalTo: editorPane.leadingAnchor).isActive = true
        editorScrollView.trailingAnchor.constraint(equalTo: editorPane.trailingAnchor).isActive = true
        editorScrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10).isActive = true
        editorScrollView.bottomAnchor.constraint(equalTo: editorPane.bottomAnchor).isActive = true

        editorPlaceholder.centerXAnchor.constraint(equalTo: editorScrollView.centerXAnchor).isActive = true
        editorPlaceholder.centerYAnchor.constraint(equalTo: editorScrollView.centerYAnchor).isActive = true
        placeholderHint.widthAnchor.constraint(equalToConstant: 280).isActive = true
    }

    private func buildLayout() {
        divider.wantsLayer = true
        divider.layer?.backgroundColor = resolvedCGColor(NSColor.separatorColor)
        divider.translatesAutoresizingMaskIntoConstraints = false

        addSubview(listPane)
        addSubview(divider)
        addSubview(editorPane)

        listPane.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
        listPane.topAnchor.constraint(equalTo: topAnchor).isActive = true
        listPane.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
        listPane.widthAnchor.constraint(equalToConstant: 340).isActive = true

        divider.leadingAnchor.constraint(equalTo: listPane.trailingAnchor).isActive = true
        divider.topAnchor.constraint(equalTo: topAnchor).isActive = true
        divider.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true

        editorPane.leadingAnchor.constraint(equalTo: divider.trailingAnchor).isActive = true
        editorPane.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
        editorPane.topAnchor.constraint(equalTo: topAnchor).isActive = true
        editorPane.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
    }

    // MARK: - Test hooks

    /// The notes the list is showing right now.
    var visibleNotesForTest: [StudyNote] { notes }

    /// The note the editor is showing right now.
    var editingNoteIdForTest: String? { currentNoteId }

    /// What the editor contains right now.
    var editorTextForTest: String { textView.string }

    /// Is the editor showing, rather than the "no note open" placeholder?
    var editorIsVisibleForTest: Bool { !editorScrollView.isHidden }

    /// Press the "New Note" button, exactly as the user does.
    func pressNewNoteForTest() {
        newNotePressed()
    }

    /// Press the real button, through the real control, the way a click does.
    ///
    /// Calling the action directly skips the button itself, so it proves less
    /// than a click does: a button that is disabled, hidden or wired to the
    /// wrong action still passes a direct call.
    func clickNewNoteButtonForTest() {
        newNoteButton.performClick(nil)
    }

    /// Is the "New Note" button actually pressable?
    var newNoteButtonIsEnabledForTest: Bool {
        newNoteButton.isEnabled && !newNoteButton.isHidden
    }

    /// Type into the editor the way the keyboard does.
    ///
    /// This goes through `insertText`, so the text view's own change
    /// notification fires — the same path a real keystroke takes. The
    /// alternative, setting the string directly, proves nothing about the
    /// wiring between the editor and the store.
    func typeIntoEditorForTest(_ text: String) {
        textView.insertText(text, replacementRange: NSRange(location: textView.string.utf16.count,
                                                              length: 0))
    }

    // MARK: - Public API

    /// Replace the visible list of notes.
    func show(notes: [StudyNote]) {
        self.notes = notes

        countLabel.stringValue = notes.isEmpty
            ? ""
            : "\(notes.count) note\(notes.count == 1 ? "" : "s")"

        let isEmpty = notes.isEmpty
        listEmptyState.isHidden = !isEmpty
        listScrollView.isHidden = isEmpty

        tableView.reloadData()

        // Keep the current row selected when the note is still on screen: the
        // controller calls this after every change, including the ones the
        // editor itself causes.
        if let id = currentNoteId, let index = notes.firstIndex(where: { $0.id == id }) {
            isUpdatingSelection = true
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            isUpdatingSelection = false
        } else if currentNoteId == nil, let first = notes.first {
            // Nothing is open yet, so open the first note. A notes desk that
            // always starts on an empty placeholder is a notes desk you have
            // to click into before it shows you anything.
            currentNoteId = first.id
            isUpdatingSelection = true
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            isUpdatingSelection = false
            loadIntoEditor(first)
        } else {
            isUpdatingSelection = true
            tableView.deselectAll(nil)
            isUpdatingSelection = false
        }
        updateRowSelectionStates()

        reconcileSelection()
        updateHeader()
    }

    /// Select a note in the list and load it into the editor.
    func select(noteId: String) {
        // Whatever was typed into the previous note belongs to that note.
        flushPendingSave()

        currentNoteId = noteId

        guard let note = notes.first(where: { $0.id == noteId }) else {
            // The note is not on screen — filtered out by the search, or
            // created after the last update — so there is nothing to show.
            updateHeader()
            return
        }

        loadIntoEditor(note)
        selectRow(withId: noteId)
    }

    /// Put a note's text into the editor.
    private func loadIntoEditor(_ note: StudyNote) {
        lastKnownBody = note.body
        textView.string = note.body
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        updateHeader()
    }

    /// Put the editor into a focused, empty state for a brand-new note.
    ///
    /// The editor needs an id to save into, so the note is made here. The
    /// controller may have made one already — it asked for a new note through
    /// `onCreateNote` and then told us to begin — and that note is adopted
    /// rather than making a second one.
    func beginNewNote() {
        // The note we are leaving gets its last word in first.
        flushPendingSave()

        // A search filter set for the notes that were already here would
        // hide the note the user has just asked for, so the filter goes.
        clearSearchFilter()

        let note = adoptFreshNote() ?? LearningStore.shared.addNote()

        currentNoteId = note.id
        lastKnownBody = note.body
        textView.string = note.body
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))

        updateHeader()
        selectRow(withId: note.id)
        window?.makeFirstResponder(textView)
    }

    /// The note the controller has just made for us, if there is one.
    ///
    /// A note with no words in it, made after the user asked for a new one,
    /// is the note they meant — as long as it is not one of the notes that
    /// were already there when they asked.
    private func adoptFreshNote() -> StudyNote? {
        guard let request = newNoteRequest else { return nil }
        return LearningStore.shared.allNotes.first { note in
            note.body.isEmpty
                && note.createdAt >= request.asked
                && !request.existing.contains(note.id)
        }
    }

    // MARK: - Auto-save

    /// The user typed. Schedule a save.
    func textDidChange(_ notification: Notification) {
        let body = textView.string

        // Loading a note into the editor changes the text as well; there is
        // nothing to save when the words have not actually changed.
        guard body != lastKnownBody else { return }

        scheduleSave()
    }

    /// Auto-save is debounced. The controller writes to disk, and a note that
    /// hit the disk on every keystroke would be a note that hit the disk very
    /// hard.
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            // The editor and the store belong to the main thread, so the
            // last step happens there. Only the waiting happens elsewhere.
            DispatchQueue.main.async { [weak self] in
                self?.flushPendingSave()
            }
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.saveDebounce,
                                                       execute: work)
    }

    /// Save right now, if there is anything to save.
    ///
    /// The controller calls this when the user leaves the module and when the
    /// app quits. The auto-save is debounced, so without those two calls the
    /// last half-second of typing can be lost.
    func flushPendingSave() {
        saveWork?.cancel()
        saveWork = nil

        guard let id = currentNoteId else { return }
        let body = textView.string
        guard body != lastKnownBody else { return }

        lastKnownBody = body
        onChangeNoteBody?(id, body)
    }

    // MARK: - Actions

    /// Ask for a brand-new note.
    ///
    /// The controller may make the note itself and select it. If it does
    /// not, we begin one here, so the button is never a dead end.
    @objc private func newNotePressed() {
        let previous = currentNoteId
        // Remember what was already there, so the note the controller makes
        // can be told apart from an old empty note that happens to match.
        newNoteRequest = (asked: Date(),
                          existing: Set(LearningStore.shared.allNotes.map(\.id)))

        onCreateNote?()

        if currentNoteId == previous {
            beginNewNote()
        }
    }

    @objc private func openDocumentPressed() {
        guard let note = currentNote else { return }
        onOpenDocument?(note)
    }

    @objc private func searchChanged() {
        onSearch?(searchField.stringValue)
    }

    /// Drop the search filter and tell the controller to show everything
    /// again.
    private func clearSearchFilter() {
        guard !searchField.stringValue.isEmpty else { return }
        searchField.stringValue = ""
        onSearch?("")
    }

    /// The search field is a filter, so it filters as you type. The action
    /// above still fires on Return, which is what a keyboard user expects.
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField, field === searchField else { return }
        onSearch?(field.stringValue)
    }

    /// Double-clicking a note opens the document it belongs to.
    @objc private func tableRowActivated() {
        let row = tableView.selectedRow
        guard row >= 0, row < notes.count else { return }
        onOpenDocument?(notes[row])
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        notes.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < notes.count else { return nil }
        let note = notes[row]

        // The table recycles rows, so a library of a thousand notes costs
        // exactly as much as a library of ten. A table view can only be
        // handed a nib to register, so the row's own identifier is what makes
        // it findable in the reuse queue.
        let cell = (tableView.makeView(withIdentifier: NoteRowView.identifier, owner: self) as? NoteRowView)
            ?? NoteRowView(frame: .zero)
        cell.identifier = NoteRowView.identifier
        cell.configure(with: note)
        cell.isRowSelected = (tableView.selectedRow == row)
        cell.onMenu = { [weak self, weak cell] noteId in
            guard let self, let cell else { return }
            self.popUpMenu(for: noteId, from: cell.menuButton)
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isUpdatingSelection else { return }

        updateRowSelectionStates()

        let row = tableView.selectedRow
        guard row >= 0, row < notes.count else { return }
        let note = notes[row]

        // Show the note straight away; the controller will usually call
        // `select(noteId:)` as well, which is harmless.
        flushPendingSave()
        currentNoteId = note.id
        lastKnownBody = note.body
        textView.string = note.body
        updateHeader()

        onSelectNote?(note)
    }

    private func updateRowSelectionStates() {
        for row in 0..<tableView.numberOfRows {
            let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NoteRowView
            cell?.isRowSelected = (row == tableView.selectedRow)
        }
    }

    private func selectRow(withId id: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        isUpdatingSelection = true
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
        isUpdatingSelection = false
        updateRowSelectionStates()
    }

    // MARK: - Row menu

    private func popUpMenu(for noteId: String, from button: NSView) {
        let menu = NSMenu()

        let open = NSMenuItem(title: "Open document", action: #selector(handleRowMenu(_:)), keyEquivalent: "")
        open.target = self
        open.representedObject = noteId
        open.tag = NotesMenuTag.open
        menu.addItem(open)

        menu.addItem(.separator())

        let delete = NSMenuItem(title: "Delete note", action: #selector(handleRowMenu(_:)), keyEquivalent: "")
        delete.target = self
        delete.representedObject = noteId
        delete.tag = NotesMenuTag.delete
        menu.addItem(delete)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
    }

    @objc private func handleRowMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let note = notes.first(where: { $0.id == id }) else { return }
        switch sender.tag {
        case NotesMenuTag.open: onOpenDocument?(note)
        case NotesMenuTag.delete: onDeleteNote?(note)
        default: break
        }
    }

    // MARK: - Editor state

    /// The note the editor is showing, if it is still on screen.
    private var currentNote: StudyNote? {
        guard let id = currentNoteId else { return nil }
        return notes.first { $0.id == id }
    }

    /// A note that has vanished from the list was either deleted or filtered
    /// out by the search. When nothing is being searched it was deleted, so
    /// the editor must stop offering a note that no longer exists.
    private func reconcileSelection() {
        guard let id = currentNoteId else { return }
        guard !notes.contains(where: { $0.id == id }) else { return }
        guard searchField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        currentNoteId = nil
        lastKnownBody = ""
        textView.string = ""
        updateHeader()
    }

    /// Bring the editor header and the placeholder in line with the state.
    private func updateHeader() {
        guard let note = currentNote else {
            // The placeholder in the middle of the pane says it better than a
            // header can, so the header stays quiet.
            editorTitleLabel.stringValue = ""
            editorSubtitleLabel.stringValue = ""
            openDocumentButton.isHidden = true
            editorPlaceholder.isHidden = false
            editorScrollView.isHidden = true
            return
        }

        editorTitleLabel.stringValue = note.documentTitle.isEmpty ? "Untitled document" : note.documentTitle
        editorTitleLabel.textColor = .labelColor
        editorSubtitleLabel.stringValue = "Updated \(NotesView.relativeDate(note.updatedAt))"
        openDocumentButton.isHidden = false
        openDocumentButton.isEnabled = !note.documentId.isEmpty
        editorPlaceholder.isHidden = true
        editorScrollView.isHidden = false
    }

    // MARK: - Appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Layer colours are resolved when they are set, so they have to be
        // refreshed when the user switches between light and dark.
        listPane.layer?.backgroundColor = resolvedCGColor(NSColor.controlBackgroundColor)
        editorPane.layer?.backgroundColor = resolvedCGColor(NSColor.textBackgroundColor)
        divider.layer?.backgroundColor = resolvedCGColor(NSColor.separatorColor)
        for row in 0..<tableView.numberOfRows {
            let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NoteRowView
            cell?.refreshAppearance()
        }
    }

    // MARK: - Dates

    /// "just now", "12 minutes ago", "yesterday", "4 days ago", "12 Oct".
    ///
    /// `RelativeDateTimeFormatter` does the hard part. The only rule added on
    /// top is that anything older than a week gets a plain date, because
    /// "23 days ago" in a list of notes is noise, not information.
    static func relativeDate(_ date: Date, relativeTo reference: Date = Date()) -> String {
        let interval = reference.timeIntervalSince(date)

        if interval < 60 { return "just now" }

        if interval < 7 * 24 * 60 * 60 {
            return relativeFormatter.localizedString(for: date, relativeTo: reference)
        }

        let sameYear = Calendar.current.component(.year, from: date)
            == Calendar.current.component(.year, from: reference)
        return (sameYear ? shortDateFormatter : datedDateFormatter).string(from: date)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return formatter
    }()

    private static let datedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()
}

// MARK: - Menu tags

enum NotesMenuTag {
    static let open = 1
    static let delete = 2
}

// MARK: - The row

/// One note in the list.
///
/// The row carries its own chrome — the first line of the note, the document
/// it belongs to, when it was last touched and a menu — so the table can
/// recycle rows instead of the list rebuilding them by hand.
final class NoteRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("NoteRowView")

    /// Called with the note's id when the row's menu button is pressed.
    var onMenu: ((String) -> Void)?

    private let selectionBackground = NSView()
    private let previewLabel = NSTextField(labelWithString: "")
    private let documentLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")

    /// The row's menu button. The list pops the menu up from here.
    let menuButton = NSButton(title: "", target: nil, action: nil)

    /// The note this row is showing.
    private(set) var noteId = ""

    /// Whether this is the row the user has selected.
    var isRowSelected = false {
        didSet { updateSelectionAppearance() }
    }

    override init(frame frameRect: NSRect) {

        // Auto Layout positions these, so the autoresizing mask must not
        // fight it — a view with the mask on keeps its old frame and is
        // never moved by its constraints.
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        documentLabel.translatesAutoresizingMaskIntoConstraints = false
        dateLabel.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: frameRect)
        // The table owns the row's frame; only the chrome inside it is ours
        // to place, so the row itself keeps its autoresizing mask.
        handOverToAutoLayout(previewLabel, documentLabel, dateLabel)

        // The accent pill is drawn by the row itself: the table's own
        // highlight is switched off so that the selected row looks like a
        // Finder sidebar row rather than a slab of solid colour.
        selectionBackground.wantsLayer = true
        selectionBackground.layer?.cornerRadius = 6
        selectionBackground.layer?.masksToBounds = true
        selectionBackground.translatesAutoresizingMaskIntoConstraints = false

        previewLabel.font = .systemFont(ofSize: 13, weight: .medium)
        previewLabel.lineBreakMode = .byTruncatingTail

        documentLabel.font = .systemFont(ofSize: 11)
        documentLabel.textColor = .secondaryLabelColor
        documentLabel.lineBreakMode = .byTruncatingTail

        dateLabel.font = .systemFont(ofSize: 11)
        dateLabel.textColor = .tertiaryLabelColor
        dateLabel.alignment = .right
        dateLabel.lineBreakMode = .byTruncatingTail

        menuButton.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More")
        menuButton.bezelStyle = .inline
        menuButton.isBordered = false
        menuButton.contentTintColor = .secondaryLabelColor
        menuButton.target = self
        menuButton.action = #selector(menuPressed)
        menuButton.toolTip = "More actions"
        menuButton.setAccessibilityLabel("Note actions")
        menuButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(selectionBackground)
        addSubview(previewLabel)
        addSubview(documentLabel)
        addSubview(dateLabel)
        addSubview(menuButton)

        selectionBackground.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4).isActive = true
        selectionBackground.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4).isActive = true
        selectionBackground.topAnchor.constraint(equalTo: topAnchor, constant: 3).isActive = true
        selectionBackground.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3).isActive = true

        previewLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12).isActive = true
        previewLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9).isActive = true
        previewLabel.trailingAnchor.constraint(equalTo: menuButton.leadingAnchor, constant: -6).isActive = true

        menuButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10).isActive = true
        menuButton.centerYAnchor.constraint(equalTo: previewLabel.centerYAnchor).isActive = true
        menuButton.widthAnchor.constraint(equalToConstant: 16).isActive = true
        menuButton.heightAnchor.constraint(equalToConstant: 16).isActive = true

        documentLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12).isActive = true
        documentLabel.topAnchor.constraint(equalTo: previewLabel.bottomAnchor, constant: 3).isActive = true
        documentLabel.trailingAnchor.constraint(equalTo: dateLabel.leadingAnchor, constant: -8).isActive = true

        dateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12).isActive = true
        dateLabel.centerYAnchor.constraint(equalTo: documentLabel.centerYAnchor).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with note: StudyNote) {
        noteId = note.id

        let preview = note.preview
        previewLabel.stringValue = preview.isEmpty ? "Untitled note" : preview
        previewLabel.textColor = preview.isEmpty ? .tertiaryLabelColor : .labelColor

        // Where the note came from. A note taken in the reader remembers
        // its chapter, so it can be found again in the book.
        documentLabel.stringValue = note.documentTitle.isEmpty
            ? note.chapterLabel
            : "\(note.documentTitle) · \(note.chapterLabel)"
        dateLabel.stringValue = NotesView.relativeDate(note.updatedAt)

        updateSelectionAppearance()
    }

    /// Redraw the accent pill after a light/dark switch.
    func refreshAppearance() {
        updateSelectionAppearance()
    }

    private func updateSelectionAppearance() {
        selectionBackground.layer?.backgroundColor = isRowSelected
            ? resolvedCGColor(Palette.wash(Palette.accent, amount: 0.16))
            : resolvedCGColor(NSColor.clear)
    }

    @objc private func menuPressed() {
        onMenu?(noteId)
    }
}
