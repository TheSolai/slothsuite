import Cocoa

// MARK: - The reader

/// The native reader for a document's briefing.
///
/// The briefing used to be readable only inside the wrapped web app, which
/// made reading it feel like using a website: no find bar, no dependable
/// selection, no typography you could settle into. This view is the opposite
/// — one real text view, system type, and chapters you can move between.
final class ReaderView: NSView {

    /// The user asked to hear one chapter read aloud.
    var onSpeakChapter: ((BriefingChapter) -> Void)?
    /// The user asked to hear the whole briefing.
    var onSpeakAll: ((Briefing) -> Void)?
    /// The user wants the pop-out window with every chapter and its script.
    var onOpenChapters: ((Briefing) -> Void)?
    /// The user wants to write a note about this document.
    var onAddNote: ((Briefing) -> Void)?
    /// Open this document in the wrapped web app.
    var onOpenInApp: ((Briefing) -> Void)?
    /// Export this briefing.
    var onExport: ((Briefing) -> Void)?
    /// The user scrolled to a different chapter — used to remember where they were.
    var onChapterChanged: ((Int) -> Void)?

    // MARK: Subviews

    private let headerView = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let authorLabel = NSTextField(labelWithString: "")
    private let actionStack = NSStackView()
    private let chipStack = NSStackView()
    private var listenButton: NSButton?
    private var playAllButton: NSButton?

    private let chapterScroll = NSScrollView()
    private let chapterStack = NSStackView()

    private let bodyScroll = NSScrollView()
    private let textView = ReaderTextView()

    private let overlay = NSView()
    private let loadingStack = NSStackView()
    private let spinner = NSProgressIndicator()
    private let loadingLabel = NSTextField(labelWithString: "")
    private let unavailableStack = NSStackView()
    private let unavailableIcon = NSImageView()
    private let unavailableLabel = NSTextField(labelWithString: "")

    // MARK: State

    private var briefing: Briefing?
    /// The character range of each chapter heading, in document order.
    /// Index 0 is the first chapter; the overview that precedes it is index 0
    /// in the public API and is not in this array.
    private var chapterRanges: [NSRange] = []
    /// The chapter the reader is looking at, 0 meaning the overview.
    private var currentChapter = 0
    /// The chapter we last told the controller about, so scrolling does not
    /// report the same chapter over and over.
    private var lastReportedChapter = 0

    private var chapterPills: [ChapterPill] = []
    /// How wide the chapter row needs to be for all of its pills.
    private var chapterRowWidth: CGFloat = 0
    private var chipStackWidth: NSLayoutConstraint?
    private var chapterBarHeight: NSLayoutConstraint?
    private var authorHeight: NSLayoutConstraint?

    // MARK: - Build

    init() {

        // Auto Layout positions these, so the autoresizing mask must not
        // fight it — a view with the mask on keeps its old frame and is
        // never moved by its constraints.
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        authorLabel.translatesAutoresizingMaskIntoConstraints = false
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        chipStack.translatesAutoresizingMaskIntoConstraints = false
        loadingStack.translatesAutoresizingMaskIntoConstraints = false
        unavailableStack.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        buildHeader()
        buildChapterBar()
        buildBody()
        buildStates()
        layOutTheView()

        // The clip view is what actually moves when the reader scrolls; the
        // text view's own bounds never change, so this is the notification
        // that means "the user moved".
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewDidScroll),
            name: NSClipView.boundsDidChangeNotification,
            object: bodyScroll.contentView
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Header

    private func buildHeader() {
        titleLabel.font = Typography.title(weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.cell?.truncatesLastVisibleLine = true
        // The title gives way before the buttons do.
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        authorLabel.font = Typography.secondary()
        authorLabel.textColor = .secondaryLabelColor
        authorLabel.lineBreakMode = .byTruncatingTail

        actionStack.orientation = .horizontal
        actionStack.alignment = .centerY
        actionStack.spacing = 8

        let listen = actionButton("Listen", symbol: "speaker.wave.2", action: #selector(listenPressed))
        listenButton = listen
        // The two the brief asked for: everything as audio, and the pop-out
        // window that holds every chapter and its script on one page.
        let playAll = actionButton("All audio", symbol: "speaker.wave.3", action: #selector(playAllPressed))
        playAllButton = playAll
        let chapters = actionButton("Chapters", symbol: "list.bullet.rectangle", action: #selector(chaptersPressed))
        let note = actionButton("Add Note", symbol: "note.text.badge.plus", action: #selector(addNotePressed))
        let open = actionButton("Open in App", symbol: "safari", action: #selector(openInAppPressed))
        let export = actionButton("Export", symbol: "square.and.arrow.up", action: #selector(exportPressed))
        actionStack.addArrangedSubview(listen)
        actionStack.addArrangedSubview(playAll)
        actionStack.addArrangedSubview(chapters)
        actionStack.addArrangedSubview(note)
        actionStack.addArrangedSubview(open)
        actionStack.addArrangedSubview(export)

        chipStack.orientation = .horizontal
        chipStack.alignment = .centerY
        chipStack.spacing = 6

        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(titleLabel)
        headerView.addSubview(authorLabel)
        headerView.addSubview(actionStack)
        headerView.addSubview(chipStack)

        titleLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor).isActive = true
        titleLabel.topAnchor.constraint(equalTo: headerView.topAnchor).isActive = true
        titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionStack.leadingAnchor, constant: -16).isActive = true

        actionStack.trailingAnchor.constraint(equalTo: headerView.trailingAnchor).isActive = true
        actionStack.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor).isActive = true

        authorLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor).isActive = true
        authorLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3).isActive = true
        authorLabel.trailingAnchor.constraint(equalTo: headerView.trailingAnchor).isActive = true
        authorHeight = authorLabel.heightAnchor.constraint(equalToConstant: 16)
        authorHeight?.isActive = true

        chipStack.leadingAnchor.constraint(equalTo: headerView.leadingAnchor).isActive = true
        chipStack.topAnchor.constraint(equalTo: authorLabel.bottomAnchor, constant: 10).isActive = true
        chipStack.bottomAnchor.constraint(equalTo: headerView.bottomAnchor).isActive = true
        chipStackWidth = chipStack.widthAnchor.constraint(equalToConstant: 0)
        chipStackWidth?.isActive = true
    }

    private func actionButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = Typography.body(weight: .medium)
        button.toolTip = title
        button.setContentHuggingPriority(.required, for: .horizontal)
        // The buttons keep their size and the title gives way instead: a
        // squeezed button is a button nobody can read.
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    // MARK: Chapter row

    private func buildChapterBar() {
        chapterScroll.hasVerticalScroller = false
        chapterScroll.hasHorizontalScroller = true
        chapterScroll.drawsBackground = false
        chapterScroll.translatesAutoresizingMaskIntoConstraints = false

        chapterStack.orientation = .horizontal
        chapterStack.alignment = .centerY
        chapterStack.spacing = 6

        // The row is the scroll view's document view and is sized by hand:
        // AppKit has no layout guide for a scroll view, and the row only
        // needs to be as wide as its pills.
        chapterScroll.documentView = chapterStack
    }

    // MARK: Body

    private func buildBody() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        // A real ⌘F find bar, and selection and copy for nothing.
        textView.usesFindBar = true
        textView.textContainerInset = NSSize(width: 16, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false

        bodyScroll.hasVerticalScroller = true
        bodyScroll.hasHorizontalScroller = false
        bodyScroll.drawsBackground = false
        bodyScroll.translatesAutoresizingMaskIntoConstraints = false
        bodyScroll.documentView = textView
    }

    // MARK: States

    private func buildStates() {
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.isHidden = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true

        loadingLabel.font = .systemFont(ofSize: 13)
        loadingLabel.textColor = .secondaryLabelColor
        loadingLabel.alignment = .center

        loadingStack.orientation = .vertical
        loadingStack.alignment = .centerX
        loadingStack.spacing = 12
        loadingStack.addArrangedSubview(spinner)
        loadingStack.addArrangedSubview(loadingLabel)

        unavailableIcon.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        unavailableIcon.contentTintColor = .tertiaryLabelColor
        unavailableIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 30, weight: .light)

        unavailableLabel.font = .systemFont(ofSize: 13)
        unavailableLabel.textColor = .secondaryLabelColor
        unavailableLabel.alignment = .center
        unavailableLabel.maximumNumberOfLines = 3
        unavailableLabel.lineBreakMode = .byWordWrapping

        unavailableStack.orientation = .vertical
        unavailableStack.alignment = .centerX
        unavailableStack.spacing = 10
        unavailableStack.isHidden = true
        unavailableStack.addArrangedSubview(unavailableIcon)
        unavailableStack.addArrangedSubview(unavailableLabel)

        overlay.addSubview(loadingStack)
        overlay.addSubview(unavailableStack)

        loadingStack.centerXAnchor.constraint(equalTo: overlay.centerXAnchor).isActive = true
        loadingStack.centerYAnchor.constraint(equalTo: overlay.centerYAnchor).isActive = true
        unavailableStack.centerXAnchor.constraint(equalTo: overlay.centerXAnchor).isActive = true
        unavailableStack.centerYAnchor.constraint(equalTo: overlay.centerYAnchor).isActive = true
    }

    // MARK: Layout

    private func layOutTheView() {
        addSubview(headerView)
        addSubview(chapterScroll)
        addSubview(bodyScroll)
        addSubview(overlay)

        headerView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28).isActive = true
        headerView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28).isActive = true
        headerView.topAnchor.constraint(equalTo: topAnchor, constant: 18).isActive = true

        chapterScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28).isActive = true
        chapterScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28).isActive = true
        chapterScroll.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 14).isActive = true
        chapterBarHeight = chapterScroll.heightAnchor.constraint(equalToConstant: 26)
        chapterBarHeight?.isActive = true

        bodyScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28).isActive = true
        bodyScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28).isActive = true
        bodyScroll.topAnchor.constraint(equalTo: chapterScroll.bottomAnchor, constant: 6).isActive = true
        bodyScroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20).isActive = true

        overlay.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
        overlay.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
        overlay.topAnchor.constraint(equalTo: topAnchor).isActive = true
        overlay.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
    }

    // MARK: - Content

    /// Render a briefing.
    func show(briefing: Briefing) {
        self.briefing = briefing

        titleLabel.stringValue = briefing.title
        let author = briefing.author.isEmpty ? briefing.filename : briefing.author
        authorLabel.stringValue = author
        authorHeight?.constant = author.isEmpty ? 0 : 16

        rebuildChips(for: briefing)
        rebuildChapterBar(for: briefing.chapters)

        let built = BriefingTextBuilder.build(briefing)
        textView.textStorage?.setAttributedString(built.string)
        textView.ruleRange = built.thesisRange
        chapterRanges = built.chapterRanges

        currentChapter = 0
        lastReportedChapter = 0
        updatePillSelection()
        bodyScroll.contentView.scroll(to: .zero)

        let hasChapters = !briefing.chapters.isEmpty
        chapterScroll.isHidden = !hasChapters
        chapterBarHeight?.constant = hasChapters ? 26 : 0
        headerView.isHidden = false
        bodyScroll.isHidden = false
        overlay.isHidden = true
    }

    /// Show a spinner-ish "Loading…" state for a document title.
    func showLoading(title: String) {
        briefing = nil
        loadingLabel.stringValue = title
        loadingStack.isHidden = false
        unavailableStack.isHidden = true
        spinner.startAnimation(nil)

        hideContent()
        overlay.isHidden = false
    }

    /// Show a calm empty state (e.g. the document has not finished synthesising).
    func showUnavailable(message: String) {
        briefing = nil
        spinner.stopAnimation(nil)
        loadingStack.isHidden = true
        unavailableStack.isHidden = false
        unavailableLabel.stringValue = message

        hideContent()
        overlay.isHidden = false
    }

    private func hideContent() {
        headerView.isHidden = true
        chapterScroll.isHidden = true
        bodyScroll.isHidden = true
        chapterBarHeight?.constant = 0
    }

    /// Open the reader's find bar.
    ///
    /// The suite's ⌘F belongs to the reader while the reader is on screen, and
    /// the find bar is already there — it just has to be asked for.
    func focusFindBar() {
        textView.performFindPanelAction(nil)
        textView.window?.makeFirstResponder(textView)
    }

    // MARK: Chips

    private func rebuildChips(for briefing: Briefing) {
        for view in chipStack.arrangedSubviews {
            chipStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        var chips: [ReaderChip] = []
        let chapters = briefing.chapters.count
        chips.append(ReaderChip(text: "\(chapters) chapter\(chapters == 1 ? "" : "s")"))
        if briefing.totalWords > 0 {
            chips.append(ReaderChip(text: "\(Self.grouped(briefing.totalWords)) words"))
        }
        if briefing.timeSavedMinutes > 0 {
            chips.append(ReaderChip(text: "\(briefing.timeSavedMinutes) min saved"))
        }
        if briefing.standardReadingMinutes > 0 {
            chips.append(ReaderChip(text: "\(Self.readingTime(briefing.standardReadingMinutes)) read"))
        }

        for chip in chips {
            chipStack.addArrangedSubview(chip)
        }

        let width = chips.reduce(CGFloat(0)) { $0 + $1.intrinsicContentSize.width }
            + CGFloat(max(0, chips.count - 1)) * chipStack.spacing
        chipStackWidth?.constant = width
    }

    private static func grouped(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }

    private static func readingTime(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        if rest == 0 { return "\(hours) hr" }
        return "\(hours) hr \(rest) min"
    }

    // MARK: Chapter bar

    private func rebuildChapterBar(for chapters: [BriefingChapter]) {
        for view in chapterStack.arrangedSubviews {
            chapterStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        chapterPills.removeAll()

        // The overview gets a pill of its own so the reader can always get
        // back to the top of the briefing.
        var pills: [ChapterPill] = []
        let overview = ChapterPill(title: "Overview", target: self, action: #selector(chapterPillPressed(_:)))
        overview.tag = 0
        pills.append(overview)

        for (index, chapter) in chapters.enumerated() {
            let pill = ChapterPill(title: "\(index + 1). \(Self.shorten(chapter.title))",
                                   target: self,
                                   action: #selector(chapterPillPressed(_:)))
            pill.tag = index + 1
            pills.append(pill)
        }

        for pill in pills {
            chapterStack.addArrangedSubview(pill)
        }
        chapterPills = pills

        let width = pills.reduce(CGFloat(0)) { $0 + $1.intrinsicContentSize.width }
            + CGFloat(max(0, pills.count - 1)) * chapterStack.spacing
        chapterRowWidth = width
        layoutChapterRow()
    }

    /// Size the chapter row to fit its pills. It is the scroll view's
    /// document view, so it is positioned by hand.
    private func layoutChapterRow() {
        let height = chapterScroll.bounds.height > 0 ? chapterScroll.bounds.height : 26
        let frame = NSRect(x: 0, y: 0, width: chapterRowWidth, height: height)
        if chapterStack.frame != frame {
            chapterStack.frame = frame
        }
    }

    override func layout() {
        super.layout()
        layoutChapterRow()
    }

    private static func shorten(_ text: String) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > 26 else { return clean }
        return String(clean.prefix(26)).trimmingCharacters(in: .whitespaces) + "…"
    }

    @objc private func chapterPillPressed(_ sender: ChapterPill) {
        goToChapter(sender.tag)
    }

    // MARK: - Jumping

    /// Jump to a chapter by index (0 = the overview before chapter one).
    func goToChapter(_ index: Int) {
        guard index >= 0 else { return }

        if index == 0 {
            lastReportedChapter = 0
            currentChapter = 0
            updatePillSelection()
            bodyScroll.contentView.scroll(to: .zero)
            onChapterChanged?(0)
            return
        }

        let chapterIndex = index - 1
        guard chapterIndex < chapterRanges.count else { return }
        guard let manager = textView.layoutManager, let container = textView.textContainer else { return }

        manager.ensureLayout(for: container)
        let range = chapterRanges[chapterIndex]
        let glyphRange = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = manager.boundingRect(forGlyphRange: glyphRange, in: container)
        guard rect.height > 0 else { return }

        // The container sits inside the text view's inset, so the heading's
        // place in the content is that much further down.
        let target = rect.minY + textView.textContainerInset.height
        lastReportedChapter = index
        currentChapter = index
        updatePillSelection()
        bodyScroll.contentView.scroll(to: NSPoint(x: 0, y: target))
        onChapterChanged?(index)
    }

    // MARK: - Tracking

    @objc private func clipViewDidScroll() {
        let index = chapterAtTopOfView()
        // Only report a chapter when it really changed: scrolling fires this
        // on every pixel, and the controller does not need a stream of
        // identical numbers.
        guard index != lastReportedChapter else { return }
        lastReportedChapter = index
        currentChapter = index
        updatePillSelection()
        onChapterChanged?(index)
    }

    /// Which chapter is the reader looking at?
    private func chapterAtTopOfView() -> Int {
        guard !chapterRanges.isEmpty else { return 0 }
        guard let manager = textView.layoutManager, let container = textView.textContainer else { return 0 }

        manager.ensureLayout(for: container)
        let visible = bodyScroll.contentView.documentVisibleRect
        // The layout manager works in the container's own coordinates, which
        // start at the text view's inset.
        let probe = NSPoint(x: 0, y: visible.minY - textView.textContainerInset.height)
        let glyph = manager.glyphIndex(for: probe, in: container)
        let character = manager.characterIndexForGlyph(at: glyph)

        var index = 0
        for (offset, range) in chapterRanges.enumerated() where range.location <= character {
            index = offset + 1
        }
        return index
    }

    private func updatePillSelection() {
        for pill in chapterPills {
            pill.isChosen = (pill.tag == currentChapter)
        }
    }

    // MARK: - Actions

    @objc private func listenPressed() {
        let menu = NSMenu()

        let chapter = NSMenuItem(title: "Read this chapter", action: #selector(speakChapter(_:)), keyEquivalent: "")
        chapter.target = self
        chapter.isEnabled = currentChapter > 0
        menu.addItem(chapter)

        let whole = NSMenuItem(title: "Read the whole briefing", action: #selector(speakEverything(_:)), keyEquivalent: "")
        whole.target = self
        menu.addItem(whole)

        guard let listenButton else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: listenButton.bounds.height + 6), in: listenButton)
    }

    @objc private func speakChapter(_ sender: NSMenuItem) {
        guard let briefing, currentChapter > 0, currentChapter <= briefing.chapters.count else { return }
        onSpeakChapter?(briefing.chapters[currentChapter - 1])
    }

    @objc private func speakEverything(_ sender: NSMenuItem) {
        guard let briefing else { return }
        onSpeakAll?(briefing)
    }

    /// Read every chapter, one after another.
    @objc private func playAllPressed() {
        guard let briefing else { return }
        onSpeakAll?(briefing)
    }

    /// Open the pop-out window with every chapter and its spoken script.
    @objc private func chaptersPressed() {
        guard let briefing else { return }
        onOpenChapters?(briefing)
    }

    @objc private func addNotePressed() {
        guard let briefing else { return }
        onAddNote?(briefing)
    }

    @objc private func openInAppPressed() {
        guard let briefing else { return }
        onOpenInApp?(briefing)
    }

    @objc private func exportPressed() {
        guard let briefing else { return }
        onExport?(briefing)
    }
}

// MARK: - The body text view

/// The text view the briefing is rendered into.
///
/// Two things it does that a plain text view does not: it rules the thesis
/// block with a hairline in the margin, and it keeps the measure — the width
/// of the text column — inside a range the eye can follow.
private final class ReaderTextView: NSTextView {

    /// The widest the text column is allowed to get. Past this the eye
    /// starts losing the start of the next line.
    var maximumMeasure: CGFloat = 660
    /// The breathing room around the column.
    var margin: CGFloat = 32

    /// The thesis block, if the briefing has one. The rule is drawn beside it.
    var ruleRange: NSRange?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawRule(in: dirtyRect)
    }

    override func layout() {
        super.layout()
        updateMeasure()
    }

    /// A hairline in the margin, the length of the thesis block.
    private func drawRule(in dirtyRect: NSRect) {
        guard let range = ruleRange, range.length > 0 else { return }
        guard let manager = layoutManager, let container = textContainer else { return }

        manager.ensureLayout(for: container)
        let glyphRange = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let containerRect = manager.boundingRect(forGlyphRange: glyphRange, in: container)
        guard containerRect.height > 0 else { return }

        // The container lives inside the text view's inset, so its rect is
        // that much further down and to the right.
        let viewRect = containerRect.offsetBy(dx: textContainerInset.width, dy: textContainerInset.height)
        let rule = NSRect(x: viewRect.minX - 14, y: viewRect.minY + 2, width: 3, height: max(0, viewRect.height - 4))
        guard rule.intersects(dirtyRect) else { return }

        let path = NSBezierPath(roundedRect: rule, xRadius: 1.5, yRadius: 1.5)
        NSColor.controlAccentColor.setFill()
        path.fill()
    }

    /// Keep the column a comfortable width, centred when there is room.
    private func updateMeasure() {
        guard let container = textContainer else { return }
        let available = bounds.width - margin * 2
        guard available > 0 else { return }

        let measure = min(maximumMeasure, available)
        let left = margin + (available - measure) / 2

        let inset = NSSize(width: left, height: textContainerInset.height)
        if textContainerInset != inset {
            textContainerInset = inset
        }
        if container.containerSize.width != measure {
            container.containerSize = NSSize(width: measure, height: CGFloat.greatestFiniteMagnitude)
        }
    }
}

// MARK: - Chapter pill

/// One chapter in the reader's chapter row: a quiet pill that lights up when
/// the reader is inside that chapter.
private final class ChapterPill: NSButton {

    var isChosen = false {
        didSet { updateAppearance() }
    }

    private var isHovering = false {
        didSet { updateAppearance() }
    }

    init(title: String, target: AnyObject?, action: Selector) {

        super.init(frame: .zero)

        self.title = title
        bezelStyle = .inline
        isBordered = false
        alignment = .center
        font = .systemFont(ofSize: 11, weight: .medium)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        widthAnchor.constraint(equalToConstant: intrinsicContentSize.width + 20).isActive = true
        heightAnchor.constraint(equalToConstant: 20).isActive = true

        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))

        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    private func updateAppearance() {
        let colour: NSColor
        if isChosen {
            // A filled pill, the way macOS marks the current row.
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.20).cgColor
            colour = .labelColor
        } else if isHovering {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
            colour = .labelColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            colour = .secondaryLabelColor
        }

        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: font as Any,
            .foregroundColor: colour
        ])
    }
}

// MARK: - A chip of metadata

/// A small pill under the title: how many chapters, how many words, how much
/// time this briefing saved.
private final class ReaderChip: NSView {

    private let label = NSTextField(labelWithString: "")

    init(text: String) {

        // Auto Layout positions these, so the autoresizing mask must not
        // fight it — a view with the mask on keeps its old frame and is
        // never moved by its constraints.
        label.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor

        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.stringValue = text

        addSubview(label)
        label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7).isActive = true
        label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7).isActive = true
        label.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: label.intrinsicContentSize.width + 14, height: 19)
    }
}

// MARK: - The briefing text

/// Turns a briefing into the attributed string the reader shows.
///
/// The type ramp and the paragraph rhythm live here rather than in the view,
/// so the view stays a view: it owns the layout and the jumps, this owns the
/// words on the page.
private final class BriefingTextBuilder {

    struct Output {
        let string: NSAttributedString
        /// The range of each chapter's heading, in document order.
        let chapterRanges: [NSRange]
        /// The range of the thesis block, so the view can rule it.
        let thesisRange: NSRange?
    }

    private let text = NSMutableAttributedString()

    // MARK: Type

    private static let bodyFont = Typography.reading()
    private static let thesisFont = NSFont.systemFont(ofSize: 19, weight: .semibold)
    private static let headingFont = NSFont.systemFont(ofSize: 13, weight: .bold)
    private static let subheadingFont = NSFont.systemFont(ofSize: 12, weight: .bold)
    private static let captionFont = Typography.secondary()
    private static let termFont = NSFont.systemFont(ofSize: 16, weight: .bold)

    // MARK: Building

    static func build(_ briefing: Briefing) -> Output {
        let builder = BriefingTextBuilder()
        var chapterRanges: [NSRange] = []
        var thesisRange: NSRange?

        builder.air()

        if !briefing.thesis.isEmpty {
            builder.heading("Executive Thesis")
            thesisRange = builder.thesis(briefing.thesis)
        }
        if !briefing.executiveSummary.isEmpty {
            builder.heading("Executive Overview")
            builder.paragraph(briefing.executiveSummary)
        }
        if !briefing.conclusions.isEmpty {
            builder.heading("Primary Conclusions")
            builder.numbered(briefing.conclusions)
        }
        if !briefing.keyPoints.isEmpty {
            builder.heading("Key Points")
            builder.bulleted(briefing.keyPoints)
        }

        for (index, chapter) in briefing.chapters.enumerated() {
            builder.air()
            chapterRanges.append(builder.chapterHeading(number: index + 1,
                                                        title: chapter.title,
                                                        pageRange: chapter.pageRange))
            if !chapter.takeaways.isEmpty {
                builder.subheading("High-impact takeaways")
                builder.numbered(chapter.takeaways)
            }
            if !chapter.glossary.isEmpty {
                builder.subheading("Glossary")
                builder.glossary(chapter.glossary)
            }
        }

        return Output(string: builder.text, chapterRanges: chapterRanges, thesisRange: thesisRange)
    }

    // MARK: Pieces

    /// A little air above a heading. Paragraph styles have no space-before,
    /// so the gap is an empty line with a small font.
    private func air() {
        append("", font: .systemFont(ofSize: 10), colour: .clear, style: Self.airStyle())
    }

    private func heading(_ title: String) {
        append(title.uppercased(), font: Self.headingFont, colour: .tertiaryLabelColor, style: Self.headingStyle())
    }

    private func subheading(_ title: String) {
        append(title.uppercased(), font: Self.subheadingFont, colour: .tertiaryLabelColor, style: Self.subheadingStyle())
    }

    private func paragraph(_ body: String) {
        append(body, font: Self.bodyFont, colour: .labelColor, style: Self.bodyStyle())
    }

    /// The thesis: a pull quote, set apart by an indent and a rule.
    private func thesis(_ body: String) -> NSRange {
        append(body, font: Self.thesisFont, colour: .secondaryLabelColor, style: Self.thesisStyle())
    }

    private func chapterHeading(number: Int, title: String, pageRange: String) -> NSRange {
        let heading = "Chapter \(number) — \(title)".uppercased()
        let range = append(heading, font: Self.headingFont, colour: .tertiaryLabelColor,
                           style: Self.headingStyle(), endsParagraph: false)
        let caption = Self.pageRange(pageRange)
        if !caption.isEmpty {
            append("   \(caption)", font: Self.captionFont, colour: .secondaryLabelColor,
                   style: Self.headingStyle())
        }
        return range
    }

    private func numbered(_ items: [String]) {
        for (index, item) in items.enumerated() {
            append("\(index + 1).", font: Self.bodyFont, colour: .tertiaryLabelColor,
                   style: Self.listStyle(), endsParagraph: false)
            append("  \(item)", font: Self.bodyFont, colour: .labelColor, style: Self.listStyle())
        }
    }

    private func bulleted(_ items: [String]) {
        for item in items {
            append("•", font: Self.bodyFont, colour: .tertiaryLabelColor,
                   style: Self.listStyle(), endsParagraph: false)
            append("  \(item)", font: Self.bodyFont, colour: .labelColor, style: Self.listStyle())
        }
    }

    /// A glossary entry: the term in bold, the definition after it.
    private func glossary(_ entries: [BriefingGlossary]) {
        for entry in entries {
            append(entry.term, font: Self.termFont, colour: .labelColor,
                   style: Self.glossaryStyle(), endsParagraph: false)
            append("  ", font: Self.bodyFont, colour: .secondaryLabelColor,
                   style: Self.glossaryStyle(), endsParagraph: false)
            append(entry.definition, font: Self.bodyFont, colour: .secondaryLabelColor,
                   style: Self.glossaryStyle())
        }
    }

    /// Add a piece of text.
    ///
    /// Every piece ends its own paragraph unless it says otherwise. Without
    /// the break, a heading and the text under it share one paragraph — which
    /// means the heading's style is applied to the whole thing and the two run
    /// together on one line.
    @discardableResult
    private func append(_ string: String,
                        font: NSFont,
                        colour: NSColor,
                        style: NSParagraphStyle,
                        endsParagraph: Bool = true) -> NSRange {
        let range = NSRange(location: text.length, length: (string as NSString).length)
        text.append(NSAttributedString(string: string, attributes: [
            .font: font,
            .foregroundColor: colour,
            .paragraphStyle: style
        ]))
        if endsParagraph {
            text.append(NSAttributedString(string: "\n", attributes: [
                .font: font,
                .foregroundColor: colour,
                .paragraphStyle: style
            ]))
        }
        return range
    }

    // MARK: Page ranges

    private static func pageRange(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("pp.") || lowered.hasPrefix("p.") { return trimmed }
        return "pp. \(trimmed)"
    }

    // MARK: Paragraph styles

    private static func bodyStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5
        style.lineHeightMultiple = 1.3
        style.paragraphSpacing = 14
        return style
    }

    private static func thesisStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.lineHeightMultiple = 1.3
        style.paragraphSpacing = 20
        // The indent leaves room for the rule; the matching negative tail
        // indent keeps the right edge of the pull quote with the body.
        style.headIndent = 22
        style.tailIndent = -22
        return style
    }

    private static func headingStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.0
        style.paragraphSpacing = 8
        return style
    }

    private static func subheadingStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.0
        style.paragraphSpacing = 6
        return style
    }

    private static func listStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        style.lineHeightMultiple = 1.3
        style.paragraphSpacing = 7
        // The number hangs into the margin; the text after it stays aligned.
        style.headIndent = 24
        style.firstLineHeadIndent = -24
        return style
    }

    private static func glossaryStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        style.lineHeightMultiple = 1.3
        style.paragraphSpacing = 9
        style.headIndent = 18
        style.firstLineHeadIndent = -18
        return style
    }

    private static func airStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.0
        style.paragraphSpacing = 0
        return style
    }
}
