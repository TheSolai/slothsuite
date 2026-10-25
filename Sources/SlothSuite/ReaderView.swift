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

    /// Called with the chapter and how far down it the reader is.
    ///
    /// Reported when the scrolling settles, not on every pixel.
    var onPositionChanged: ((Int, Double) -> Void)?

    /// The pending position report, if a newer one has replaced it.
    private var positionWork: DispatchWorkItem?

    // MARK: Subviews

    private let headerView = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let authorLabel = NSTextField(labelWithString: "")
    private let actionStack = NSStackView()
    private let chipStack = NSStackView()
    private var listenButton: NSButton?
    private var playAllButton: NSButton?

    /// The band's numbers and word cloud, at the top of the reader.
    private let overviewView = ReaderOverviewView()

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

    /// The book's vocabulary, indexed so a term can be followed to every
    /// chapter that uses it.
    private var vocabulary = ReaderVocabulary()

    /// The term pop-up: what a chip means, and where the reader can go next.
    private let termPopUp = ReaderTermPopUpController()

    /// The chips of metadata under the title. Kept so their colours can be
    /// re-applied after a light/dark switch.
    private var chips: [ReaderChip] = []
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
        overviewView.translatesAutoresizingMaskIntoConstraints = false
        loadingStack.translatesAutoresizingMaskIntoConstraints = false
        unavailableStack.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        buildHeader()
        buildChapterBar()
        buildBody()
        buildStates()
        layOutTheView()

        // The chips and the keyword tags are the reader's way into the
        // book. The text view knows where they are; these are what happen
        // when the reader reaches for one.
        textView.onChipHovered = { [weak self] chip, rect in
            self?.showChip(chip, at: rect)
        }
        textView.onKeywordHovered = { [weak self] keyword, rect in
            self?.showKeyword(keyword, at: rect)
        }
        textView.onKeywordClicked = { [weak self] keyword, rect in
            self?.showKeyword(keyword, at: rect)
        }
        textView.onPointerLeft = { [weak self] in
            self?.termPopUp.scheduleHide()
        }

        // A word in the cloud is a way into the book: it goes to the first
        // chapter that uses the word and flashes it there.
        overviewView.onWord = { [weak self] word in
            self?.jump(to: word.chapter, flash: word.range)
        }

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
        listen.contentTintColor = Palette.teal
        listen.setColoredTitle("Listen", color: Palette.teal, font: Typography.body(weight: .medium))
        // The two the brief asked for: everything as audio, and the pop-out
        // window that holds every chapter and its script on one page.
        let playAll = actionButton("All audio", symbol: "speaker.wave.3", action: #selector(playAllPressed))
        playAllButton = playAll
        playAll.contentTintColor = Palette.accent
        playAll.setColoredTitle("All audio", color: Palette.accent, font: Typography.body(weight: .medium))
        let chapters = actionButton("Chapters", symbol: "list.bullet.rectangle", action: #selector(chaptersPressed))
        chapters.contentTintColor = Palette.accent
        chapters.setColoredTitle("Chapters", color: Palette.accent, font: Typography.body(weight: .medium))
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
        // The row of chips is what tells the header how tall it is. Without
        // this the header's height is ambiguous, and Auto Layout resolves an
        // ambiguous height by stretching the header over the whole page.
        chipStack.heightAnchor.constraint(equalToConstant: 19).isActive = true
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
        addSubview(overviewView)
        addSubview(chapterScroll)
        addSubview(bodyScroll)
        addSubview(overlay)

        headerView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28).isActive = true
        headerView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28).isActive = true
        headerView.topAnchor.constraint(equalTo: topAnchor, constant: 18).isActive = true

        chapterScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28).isActive = true
        chapterScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28).isActive = true
        overviewView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28).isActive = true
        overviewView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28).isActive = true
        overviewView.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 12).isActive = true

        chapterScroll.topAnchor.constraint(equalTo: overviewView.bottomAnchor, constant: 12).isActive = true
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
    ///
    /// `position` is where the reader had got to last time. Passing it puts
    /// them back there instead of at the top, which is the whole point of
    /// remembering a place.
    func show(briefing: Briefing, restoring position: ReadingPosition? = nil) {
        self.briefing = briefing

        titleLabel.stringValue = briefing.title
        let author = briefing.author.isEmpty ? briefing.filename : briefing.author
        authorLabel.stringValue = author
        authorHeight?.constant = author.isEmpty ? 0 : 16

        rebuildChips(for: briefing)
        rebuildChapterBar(for: briefing.chapters)

        termPopUp.dismiss()

        let built = BriefingTextBuilder.build(briefing)
        textView.textStorage?.setAttributedString(built.string)
        textView.ruleRange = built.thesisRange
        textView.ruleRanges = built.ruleRanges
        textView.cards = built.cards
        // The chips and the keyword tags are the reader's way into the
        // book, so the text view has to know where they are before it can
        // say which one the pointer is over.
        textView.chips = built.chips
        textView.keywords = built.keywords
        // The panels and the rules are drawn by the text view itself, so a
        // change to the text only marks the text as dirty — they would
        // never be painted without this.
        textView.needsDisplay = true
        chapterRanges = built.chapterRanges

        // The band and the pop-up share one index, so a word in the cloud
        // leads to the same place a chip does.
        vocabulary.build(chips: built.chips, keywords: built.keywords)
        overviewView.show(briefing: briefing, vocabulary: vocabulary)
        overviewView.isHidden = false
        overviewView.setHeight(ReaderOverviewView.height)

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

        // Put the reader back where they were.
        //
        // The restore needs the text view's layout, and a document that
        // is opened before the window has settled has not got one yet.
        // When that happens the place is held and applied as soon as the
        // layout is there — otherwise the reader silently comes back to
        // the top of the book, and reports the top as the reader's place,
        // which overwrites the place that was saved.
        pendingRestore = nil
        positionWork?.cancel()
        positionWork = nil
        if let position, position.chapter > 0 {
            if !moveToChapter(position.chapter, fraction: position.scroll, report: false) {
                pendingRestore = (position.chapter, position.scroll)
            }
        }
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
        overviewView.isHidden = true
        overviewView.setHeight(0)
        overviewView.clear()
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
        chips.append(ReaderChip(text: "\(chapters) chapter\(chapters == 1 ? "" : "s")", colour: Palette.teal))
        if briefing.totalWords > 0 {
            chips.append(ReaderChip(text: "\(Self.grouped(briefing.totalWords)) words", colour: Palette.blue))
        }
        if briefing.timeSavedMinutes > 0 {
            chips.append(ReaderChip(text: "\(briefing.timeSavedMinutes) min saved", colour: Palette.gold))
        }
        if briefing.standardReadingMinutes > 0 {
            chips.append(ReaderChip(text: "\(Self.readingTime(briefing.standardReadingMinutes)) read",
                                    colour: Palette.accent))
        }

        for chip in chips {
            chipStack.addArrangedSubview(chip)
        }
        self.chips = chips

        let width = chips.reduce(CGFloat(0)) { $0 + $1.intrinsicContentSize.width }
            + CGFloat(max(0, chips.count - 1)) * chipStack.spacing
        chipStackWidth?.constant = width
    }

    /// Re-apply every colour that was resolved when a view was built.
    ///
    /// A layer's background colour is resolved at the moment it is set, so
    /// after the user switches macOS between light and dark the chips and
    /// pills keep the colours of the appearance they were built in — which
    /// on a dark background means pale text on a pale wash, unreadable.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        for chip in chips {
            chip.refreshAppearance()
        }
        for pill in chapterPills {
            pill.refreshAppearance()
        }
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
        applyPendingRestore()
    }

    /// Put the reader back to a place that could not be applied earlier.
    ///
    /// The text view is not laid out when a document is first shown, so
    /// there is nowhere to scroll to yet. The place is kept until there
    /// is.
    private func applyPendingRestore() {
        guard let pending = pendingRestore else { return }
        guard moveToChapter(pending.chapter, fraction: pending.scroll, report: false) else {
            return
        }
        pendingRestore = nil
        // The reader is where it was asked to be now, so it can say so.
        schedulePositionReport()
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
            schedulePositionReport()
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
        // place in the content is that much further down. The headroom
        // keeps the whole line in view rather than slicing its top off.
        let target = rect.minY + textView.textContainerInset.height - Self.chapterHeadroom
        lastReportedChapter = index
        currentChapter = index
        updatePillSelection()
        bodyScroll.contentView.scroll(to: NSPoint(x: 0, y: target))
        onChapterChanged?(index)
        schedulePositionReport()
    }

    /// Move to a chapter, and to a fraction of the way down it.
    ///
    /// The fraction is what makes the reader come back to the same *line*,
    /// not just the same chapter. It is measured against the chapter's own
    /// height, so it survives a change of window size.
    ///
    /// Returns false when the move could not be made -- the text has not
    /// been laid out yet, so there is nowhere to scroll to. The scroll
    /// itself can be swallowed too: a scroll view with no height yet
    /// cannot move, and the reader would then believe it was at the top
    /// of the book. So the move is checked, not assumed.
    @discardableResult
    private func moveToChapter(_ index: Int, fraction: Double, report: Bool) -> Bool {
        guard index > 0, index - 1 < chapterRanges.count else { return false }
        guard let span = chapterSpan(index) else { return false }

        let clamped = min(max(fraction, 0), 1)
        let target = span.start + span.height * clamped - Self.chapterHeadroom

        bodyScroll.contentView.scroll(to: NSPoint(x: 0, y: target))

        // Did the scroll land? A scroll view that has not been given a
        // height swallows the scroll and stays where it was.
        let visible = bodyScroll.contentView.documentVisibleRect
        guard abs(visible.minY - target) < 4 else { return false }

        currentChapter = index
        lastReportedChapter = index
        updatePillSelection()
        if report { onChapterChanged?(index) }
        return true
    }

    // MARK: - Following a term

    /// Take the reader to a place in the book, and show them they got there.
    ///
    /// A jump that moves the page without saying so is a jump the reader has
    /// to find their place in again, which is worse than not jumping at all.
    /// The term is flashed, so the eye is sent to the right line.
    private func jump(to chapter: Int, flash range: NSRange?) {
        guard chapter > 0 else { return }

        if let range, range.length > 0 {
            scroll(to: range)
        } else {
            goToChapter(chapter)
        }

        if let range, range.length > 0 {
            textView.flash(range)
        }
    }

    /// Scroll so a range sits near the top of the column.
    private func scroll(to range: NSRange) {
        // The chapter a range belongs to is a fact about the book, not a
        // guess about where the page is, so it is known even when the text
        // has not been laid out and the scroll cannot be made yet.
        let chapter = chapter(for: range.location)
        currentChapter = chapter
        lastReportedChapter = chapter
        updatePillSelection()

        guard let manager = textView.layoutManager, let container = textView.textContainer else { return }
        manager.ensureLayout(for: container)

        let glyphRange = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = manager.boundingRect(forGlyphRange: glyphRange, in: container)
        guard rect.height > 0 else { return }

        let target = rect.minY + textView.textContainerInset.height - Self.chapterHeadroom
        bodyScroll.contentView.scroll(to: NSPoint(x: 0, y: target))

        // The place is only reported once the reader is actually there.
        onChapterChanged?(chapter)
        schedulePositionReport()
    }

    /// The chapter a character belongs to.
    private func chapter(for character: Int) -> Int {
        var index = 0
        for (offset, range) in chapterRanges.enumerated() where range.location <= character {
            index = offset + 1
        }
        return index
    }

    /// The title of a chapter, for the pop-up to name.
    private func chapterTitle(_ chapter: Int) -> String {
        guard let briefing, chapter > 0, chapter <= briefing.chapters.count else {
            return "Chapter \(chapter)"
        }
        let title = briefing.chapters[chapter - 1].title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Chapter \(chapter)" : title
    }

    /// Where a key term sits in a given chapter.
    private func range(ofTerm name: String, inChapter chapter: Int) -> NSRange? {
        let key = ReaderVocabulary.normalise(name)
        return vocabulary.keyTerms.first {
            $0.chapter == chapter && ReaderVocabulary.normalise($0.name) == key
        }?.range
    }

    /// Where a keyword sits in a given chapter.
    private func range(ofKeyword name: String, inChapter chapter: Int) -> NSRange? {
        let key = ReaderVocabulary.normalise(name)
        return vocabulary.keywords.first {
            $0.chapter == chapter && ReaderVocabulary.normalise($0.name) == key
        }?.range
    }

    // MARK: - The pop-up

    /// Show what a key term means, and where the reader can go next.
    private func showChip(_ chip: ReaderChipInfo, at rect: NSRect) {
        var sections: [ReaderTermSection] = []

        // The same term, in other chapters.
        let elsewhere = vocabulary.chapters(forTerm: chip.term).filter { $0 != chip.chapter }
        if !elsewhere.isEmpty {
            let rows = elsewhere.map { chapter in
                ReaderTermJump(title: chapterTitle(chapter),
                               detail: "Chapter \(chapter)",
                               action: { [weak self] in
                                   guard let self else { return }
                                   let range = self.range(ofTerm: chip.term, inChapter: chapter)
                                   self.termPopUp.dismiss()
                                   self.jump(to: chapter, flash: range)
                               })
            }
            sections.append(ReaderTermSection(heading: "Also in", rows: rows))
        }

        // The terms whose definitions talk about this one.
        let term = ReaderKeyTerm(name: chip.term,
                                 word: chip.word,
                                 definition: chip.definition,
                                 chapter: chip.chapter,
                                 range: chip.range)
        let related = vocabulary.related(to: term)
        if !related.isEmpty {
            let rows = related.prefix(6).map { other in
                ReaderTermJump(title: other.name,
                               detail: "Chapter \(other.chapter)",
                               action: { [weak self] in
                                   guard let self else { return }
                                   self.termPopUp.dismiss()
                                   self.jump(to: other.chapter, flash: other.range)
                               })
            }
            sections.append(ReaderTermSection(heading: "Related key terms", rows: Array(rows)))
        }

        termPopUp.present(term: chip.term,
                          definition: chip.definition,
                          sections: sections,
                          relativeTo: rect,
                          of: textView)
    }

    /// Show where a keyword is used, and the key terms that talk about it.
    private func showKeyword(_ keyword: ReaderKeywordInfo, at rect: NSRect) {
        var sections: [ReaderTermSection] = []

        let chapters = vocabulary.chapters(forKeyword: keyword.keyword)
        if !chapters.isEmpty {
            let rows = chapters.map { chapter in
                ReaderTermJump(title: chapterTitle(chapter),
                               detail: "Chapter \(chapter)",
                               action: { [weak self] in
                                   guard let self else { return }
                                   let range = self.range(ofKeyword: keyword.keyword, inChapter: chapter)
                                   self.termPopUp.dismiss()
                                   self.jump(to: chapter, flash: range)
                               })
            }
            sections.append(ReaderTermSection(heading: "Appears in", rows: rows))
        }

        let terms = vocabulary.terms(mentioning: keyword.keyword)
        if !terms.isEmpty {
            let rows = terms.prefix(6).map { term in
                ReaderTermJump(title: term.name,
                               detail: "Chapter \(term.chapter)",
                               action: { [weak self] in
                                   guard let self else { return }
                                   self.termPopUp.dismiss()
                                   self.jump(to: term.chapter, flash: term.range)
                               })
            }
            sections.append(ReaderTermSection(heading: "Key terms that mention it", rows: Array(rows)))
        }

        termPopUp.present(term: keyword.keyword,
                          definition: "A keyword in \(chapterTitle(keyword.chapter)).",
                          sections: sections,
                          relativeTo: rect,
                          of: textView)
    }

    /// The vertical span of a chapter, in the scroll view's coordinates.
    ///
    /// A chapter ends where the next one begins — or at the end of the text,
    /// for the last one.
    private func chapterSpan(_ index: Int) -> (start: CGFloat, height: CGFloat)? {
        guard index > 0, index - 1 < chapterRanges.count else { return nil }
        guard let manager = textView.layoutManager, let container = textView.textContainer else { return nil }

        manager.ensureLayout(for: container)

        let range = chapterRanges[index - 1]
        let glyphRange = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = manager.boundingRect(forGlyphRange: glyphRange, in: container)
        guard rect.height > 0 else { return nil }

        // The container sits inside the text view's inset, so the heading's
        // place in the content is that much further down.
        let start = rect.minY + textView.textContainerInset.height

        let end: CGFloat
        if index < chapterRanges.count {
            let nextRange = chapterRanges[index]
            let nextGlyph = manager.glyphRange(forCharacterRange: nextRange, actualCharacterRange: nil)
            let nextRect = manager.boundingRect(forGlyphRange: nextGlyph, in: container)
            end = nextRect.minY + textView.textContainerInset.height
        } else {
            end = start + rect.height
        }

        guard end > start else { return nil }
        return (start, end - start)
    }

    /// How far down the current chapter the reader is, from 0 to 1.
    private func scrollFraction() -> Double {
        guard let span = chapterSpan(currentChapter) else { return 0 }
        let visible = bodyScroll.contentView.documentVisibleRect
        let offset = visible.minY - span.start
        return min(max(offset / span.height, 0), 1)
    }

    /// A place to put the reader back to, once the text has been laid out.
    ///
    /// The restore needs the text view's layout, and a document opened
    /// before the window has settled does not have one yet. While this is
    /// set the reader's place is not reported: what is on screen is the
    /// top of the book, not where the reader was, and reporting it would
    /// overwrite the place that was saved.
    private var pendingRestore: (chapter: Int, scroll: Double)?

    /// The room left above a chapter heading when the reader jumps to it.
    ///
    /// A heading scrolled flush to the top of the text column has its
    /// ascenders sliced off by the edge of the scroll view, which reads as
    /// a rendering fault rather than as a position. A few points of
    /// headroom puts the whole line in view.
    private static let chapterHeadroom: CGFloat = 12

    // MARK: - Tracking

    @objc private func clipViewDidScroll() {
        let index = chapterAtTopOfView()
        // Only report a chapter when it really changed: scrolling fires this
        // on every pixel, and the controller does not need a stream of
        // identical numbers.
        if index != lastReportedChapter {
            lastReportedChapter = index
            currentChapter = index
            updatePillSelection()
            onChapterChanged?(index)
        }
        // While the reader is on its way back to a saved place, where it
        // is on screen is not where the reader was.
        if pendingRestore != nil { return }
        schedulePositionReport()
    }

    /// Report where the reader is, once the scrolling has settled.
    ///
    /// Scrolling fires on every pixel, so the position is only reported when
    /// the reader stops moving — otherwise the store would be rewritten
    /// dozens of times a second.
    private func schedulePositionReport() {
        positionWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.onPositionChanged?(self.currentChapter, self.scrollFraction())
        }
        positionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Scroll the body down, for the snapshot harness.
    ///
    /// The reader is long, and a capture of the top of it says nothing
    /// about the panels further down.
    func scrollBodyForTest(by amount: CGFloat) {
        let visible = bodyScroll.contentView.documentVisibleRect
        bodyScroll.contentView.scroll(to: NSPoint(x: 0, y: visible.minY + amount))
    }

    /// Report the position now, without waiting for the scrolling to settle.
    ///
    /// Called when the reader is put away, so the place is saved even if the
    /// reader is still moving when they leave.
    func flushPosition() {
        positionWork?.cancel()
        positionWork = nil
        // A place that has not been applied yet is not the reader's place.
        if pendingRestore != nil { return }
        onPositionChanged?(currentChapter, scrollFraction())
    }

    /// The chapter the reader is looking at.
    var currentChapterIndex: Int { currentChapter }

    /// The pop-up's own view, so it can be looked at without a pointer.
    var termPopUpViewForInspection: NSView? { termPopUp.contentViewForInspection }

    /// The chips and the keyword tags, for the self-test.
    var readerTermsForTest: ([ReaderChipInfo], [ReaderKeywordInfo]) { (textView.chips, textView.keywords) }

    /// The briefing on show, for the self-test.
    var briefingForTest: Briefing? { briefing }

    /// Follow a keyword, the way clicking its tag does.
    ///
    /// Returns the chapter the reader landed on, and whether the term was
    /// flashed there. A keyword the reader cannot follow is a keyword that
    /// is only a label.
    func followKeywordForTest() -> (chapter: Int, flashed: Bool) {
        let keyword = textView.keywords.first(where: { $0.chapter == currentChapter })
            ?? textView.keywords.first
        guard let keyword else { return (0, false) }

        let chapters = vocabulary.chapters(forKeyword: keyword.keyword)
        guard let first = chapters.first else { return (0, false) }

        let range = self.range(ofKeyword: keyword.keyword, inChapter: first)
        jump(to: first, flash: range)
        return (currentChapter, textView.hasFlashForTest)
    }

    /// Open the pop-up for a term, for the snapshot harness.
    ///
    /// A pop-up only appears under a pointer, and a snapshot has no pointer,
    /// so this opens the same pop-up the pointer would.
    func showTermPopUpForTest() {
        let chip = textView.chips.first(where: { $0.chapter == currentChapter })
            ?? textView.chips.first
        guard let chip else { return }
        showChip(chip, at: textView.rect(for: chip.range))
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
/// Three things it does that a plain text view does not: it draws the
/// tinted panels the text sits on, it rules the chapter headings with a
/// hairline, and it paints the numbered badge in front of each takeaway.
private final class ReaderTextView: NSTextView {

    /// The widest the text column is allowed to get. Past this the eye
    /// starts losing the start of the next line.
    var maximumMeasure: CGFloat = 660
    /// The breathing room around the column.
    var margin: CGFloat = 32

    /// The thesis block, if the briefing has one. The rule is drawn beside it.
    var ruleRange: NSRange?

    /// The ranges that get a hairline under them — one per chapter heading.
    var ruleRanges: [NSRange] = []

    /// The tinted panels drawn behind the text.
    var cards: [ReaderCard] = []

    /// The term chips, so the reader can be told which one they are over.
    var chips: [ReaderChipInfo] = []

    /// The keyword tags, which the reader can click.
    var keywords: [ReaderKeywordInfo] = []

    /// The pointer moved over a chip.
    var onChipHovered: ((ReaderChipInfo, NSRect) -> Void)?
    /// The pointer moved over a keyword tag.
    var onKeywordHovered: ((ReaderKeywordInfo, NSRect) -> Void)?
    /// The reader clicked a keyword tag.
    var onKeywordClicked: ((ReaderKeywordInfo, NSRect) -> Void)?
    /// The pointer left the text.
    var onPointerLeft: (() -> Void)?

    /// The chip the pointer is over, so the pop-up is not shown twice.
    private var hoveredChip: ReaderChipInfo?
    /// The keyword the pointer is over.
    private var hoveredKeyword: ReaderKeywordInfo?

    /// The range being flashed, and when the flash began.
    private var flashRange: NSRange?
    private var flashStarted: Date?
    private var flashTimer: Timer?

    override func draw(_ dirtyRect: NSRect) {
        // The panels are drawn first so the text sits on top of them.
        drawCards(in: dirtyRect)
        drawFlash(in: dirtyRect)
        super.draw(dirtyRect)
        drawRules(in: dirtyRect)
        drawRule(in: dirtyRect)
    }

    // MARK: The pointer

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The pop-up follows the pointer, so the window has to be told to
        // report the mouse moving.
        window?.acceptsMouseMovedEvents = true
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = characterIndex(at: point) else {
            clearHover()
            return
        }

        if let chip = chips.first(where: { NSLocationInRange(index, $0.range) }) {
            if hoveredChip != chip {
                hoveredChip = chip
                onChipHovered?(chip, rect(for: chip.range))
            }
            NSCursor.pointingHand.set()
            return
        }

        if let keyword = keywords.first(where: { NSLocationInRange(index, $0.range) }) {
            if hoveredKeyword != keyword {
                hoveredKeyword = keyword
                onKeywordHovered?(keyword, rect(for: keyword.range))
            }
            NSCursor.pointingHand.set()
            return
        }

        clearHover()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        clearHover()
        onPointerLeft?()
    }

    /// A keyword tag is a link, so clicking it opens the pop-up rather than
    /// moving the insertion point.
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = characterIndex(at: point),
           let keyword = keywords.first(where: { NSLocationInRange(index, $0.range) }) {
            onKeywordClicked?(keyword, rect(for: keyword.range))
            return
        }
        super.mouseUp(with: event)
    }

    /// Nothing is under the pointer any more.
    private func clearHover() {
        if hoveredChip != nil || hoveredKeyword != nil {
            hoveredChip = nil
            hoveredKeyword = nil
        }
        NSCursor.arrow.set()
    }

    /// The character under a point in the text view.
    private func characterIndex(at point: NSPoint) -> Int? {
        guard let manager = layoutManager, let container = textContainer else { return nil }
        guard container.size.width > 0 else { return nil }
        manager.ensureLayout(for: container)

        // The container sits inside the text view's inset, so the point has
        // to be moved into the container's own coordinates.
        let inset = textContainerInset
        let converted = NSPoint(x: point.x - inset.width, y: point.y - inset.height)
        let glyph = manager.glyphIndex(for: converted, in: container)
        return manager.characterIndexForGlyph(at: glyph)
    }

    /// The rectangle a range occupies, in the text view's own coordinates.
    func rect(for range: NSRange) -> NSRect {
        guard let manager = layoutManager, let container = textContainer else { return .zero }
        manager.ensureLayout(for: container)

        let glyphRange = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let bounds = manager.boundingRect(forGlyphRange: glyphRange, in: container)
        return NSRect(x: bounds.minX + textContainerInset.width,
                      y: bounds.minY + textContainerInset.height,
                      width: bounds.width,
                      height: bounds.height)
    }

    // MARK: The flash

    /// Flash a range, so the reader can see where they landed.
    func flash(_ range: NSRange) {
        guard range.length > 0 else { return }

        flashRange = range
        flashStarted = Date()

        flashTimer?.invalidate()
        flashTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let started = self.flashStarted, Date().timeIntervalSince(started) > 1.5 {
                self.flashRange = nil
                self.flashStarted = nil
                self.flashTimer?.invalidate()
                self.flashTimer = nil
            }
            self.needsDisplay = true
        }
        needsDisplay = true
    }

    /// Is a term being flashed?
    var hasFlashForTest: Bool { flashRange != nil }

    /// Paint the flash behind the text.
    ///
    /// Gold, because the accent colour is what the panels and the chips are
    /// drawn in, and a flash that looks like one of them is not noticed.
    private func drawFlash(in dirtyRect: NSRect) {
        guard let range = flashRange, range.length > 0, let started = flashStarted else { return }
        guard let manager = layoutManager, let container = textContainer else { return }
        manager.ensureLayout(for: container)

        let elapsed = Date().timeIntervalSince(started)
        let strength = max(0, 1 - elapsed / 1.5)
        guard strength > 0 else { return }

        let glyphRange = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let bounds = manager.boundingRect(forGlyphRange: glyphRange, in: container)
        guard bounds.height > 0 else { return }

        let rect = NSRect(x: textContainerInset.width + bounds.minX - 4,
                          y: textContainerInset.height + bounds.minY - 3,
                          width: bounds.width + 8,
                          height: bounds.height + 6)
        guard rect.intersects(dirtyRect) else { return }

        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        resolvedColour(Palette.wash(Palette.gold, amount: 0.55 * strength)).setFill()
        path.fill()
    }

    override func layout() {
        super.layout()
        updateMeasure()
    }

    // MARK: Cards

    /// Paint the tinted panels behind the text.
    ///
    /// A panel spans the whole text column, not just the words: a card
    /// that stopped halfway through a line would look like a mistake.
    private func drawCards(in dirtyRect: NSRect) {
        guard !cards.isEmpty else { return }
        guard let manager = layoutManager, let container = textContainer else { return }

        manager.ensureLayout(for: container)
        let width = container.size.width
        guard width > 0 else { return }

        for card in cards {
            let glyphRange = manager.glyphRange(forCharacterRange: card.range, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { continue }
            let bounds = manager.boundingRect(forGlyphRange: glyphRange, in: container)
            guard bounds.height > 0 else { continue }

            let rect = NSRect(x: textContainerInset.width,
                              y: bounds.minY + textContainerInset.height,
                              width: width,
                              height: bounds.height)
                .insetBy(dx: -13, dy: -6)
            guard rect.intersects(dirtyRect) else { continue }

            let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
            resolvedColour(card.kind.fill).setFill()
            path.fill()

            let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
            resolvedColour(Palette.wash(card.kind.accent, amount: 0.30)).setStroke()
            border.lineWidth = 1
            border.stroke()

            if let badge = card.badge {
                drawBadge(badge, in: rect, card: card, manager: manager)
            }
        }
    }

    /// The numbered circle in front of a takeaway.
    ///
    /// It is painted rather than pasted in as an image so that it follows
    /// the system appearance: an image freezes the colour it was drawn
    /// with, and stays violet in the dark appearance or pale grey in the
    /// light one.
    private func drawBadge(_ number: Int,
                           in cardRect: NSRect,
                           card: ReaderCard,
                           manager: NSLayoutManager) {
        let glyphRange = manager.glyphRange(forCharacterRange: card.range, actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return }

        // The badge belongs on the first line of the card. The container's
        // coordinates run upwards, so the first line is at the far end of
        // the range. Its centre is taken from the line itself rather than
        // from the card, because the card is padded and the badge is not.
        let line = manager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
        let diameter: CGFloat = 22
        let centre = NSPoint(x: cardRect.minX + 27,
                             y: line.midY + textContainerInset.height - 2)

        let circle = NSRect(x: centre.x - diameter / 2,
                            y: centre.y - diameter / 2,
                            width: diameter,
                            height: diameter)
        let path = NSBezierPath(ovalIn: circle)
        resolvedColour(card.kind.accent).setFill()
        path.fill()

        let text = NSAttributedString(string: "\(number)", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: NSColor.white
        ])
        let bounds = text.size()
        text.draw(at: NSPoint(x: circle.midX - bounds.width / 2,
                              y: circle.midY - bounds.height / 2))
    }

    /// A hairline under each chapter heading.
    private func drawRules(in dirtyRect: NSRect) {
        guard !ruleRanges.isEmpty else { return }
        guard let manager = layoutManager, let container = textContainer else { return }

        manager.ensureLayout(for: container)
        let width = container.size.width
        guard width > 0 else { return }

        for range in ruleRanges {
            let glyphRange = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { continue }
            let bounds = manager.boundingRect(forGlyphRange: glyphRange, in: container)
            guard bounds.height > 0 else { continue }

            let line = NSRect(x: textContainerInset.width,
                              y: bounds.maxY + textContainerInset.height + 5,
                              width: width,
                              height: 1)
            guard line.intersects(dirtyRect) else { continue }

            resolvedColour(Palette.wash(Palette.accent, amount: 0.25)).setFill()
            NSBezierPath(rect: line).fill()
        }
    }

    /// A hairline in the margin, the length of the thesis block.
    private func drawRule(in dirtyRect: NSRect) {
        guard let range = ruleRange, range.length > 0 else { return }
        guard let manager = layoutManager, let container = textContainer else { return }

        manager.ensureLayout(for: container)
        let glyphRange = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let containerRect = manager.boundingRect(forGlyphRange: glyphRange, in: container)
        guard containerRect.height > 0 else { return }

        // The rule lives in the thesis paragraph's indent, which is *inside*
        // the text container. Anything drawn to the left of the container is
        // clipped away by NSTextView, so the offset is measured from the
        // container's own left edge — not from the text view's.
        let rule = NSRect(x: textContainerInset.width + 9,
                          y: containerRect.minY + textContainerInset.height,
                          width: 3,
                          height: containerRect.height)
        guard rule.intersects(dirtyRect) else { return }

        let path = NSBezierPath(roundedRect: rule, xRadius: 1.5, yRadius: 1.5)
        resolvedColour(Palette.accent).setFill()
        path.fill()
    }

    /// A colour resolved against the window's appearance.
    ///
    /// A `CGColor` keeps the colour it was given, so a dynamic colour has
    /// to be resolved before it is drawn. The appearance is the window's,
    /// because AppKit updates the tree from the top down and a child's own
    /// appearance is still the old one while it repaints.
    private func resolvedColour(_ colour: NSColor) -> NSColor {
        NSColor(cgColor: resolvedCGColor(colour)) ?? colour
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
            layer?.backgroundColor = resolvedCGColor(Palette.wash(Palette.accent, amount: 0.18))
            colour = .labelColor
        } else if isHovering {
            layer?.backgroundColor = resolvedCGColor(NSColor.labelColor.withAlphaComponent(0.07))
            colour = .labelColor
        } else {
            layer?.backgroundColor = resolvedCGColor(NSColor.clear)
            colour = .secondaryLabelColor
        }

        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: font as Any,
            .foregroundColor: colour
        ])
    }

    /// Re-apply the colours after a light/dark switch.
    func refreshAppearance() {
        updateAppearance()
    }
}

// MARK: - A chip of metadata

/// A small pill under the title: how many chapters, how many words, how much
/// time this briefing saved.
private final class ReaderChip: NSView {

    private let label = NSTextField(labelWithString: "")

    /// The colour the chip wears. Each kind of fact gets its own colour, so
    /// the row of chips under the title reads at a glance.
    private let colour: NSColor

    init(text: String, colour: NSColor = Palette.teal) {
        self.colour = colour

        // Auto Layout positions these, so the autoresizing mask must not
        // fight it — a view with the mask on keeps its old frame and is
        // never moved by its constraints.
        label.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = resolvedCGColor(Palette.wash(colour, amount: 0.12))

        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = colour
        label.alignment = .center
        label.stringValue = text

        addSubview(label)
        label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7).isActive = true
        label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7).isActive = true
        label.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Re-apply the colours after a light/dark switch.
    ///
    /// A layer's background colour is resolved when it is set, so a chip
    /// built in the light appearance keeps its pale wash after the user
    /// switches to dark.
    func refreshAppearance() {
        layer?.backgroundColor = resolvedCGColor(Palette.wash(colour, amount: 0.12))
        label.textColor = colour
    }

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
///
/// The shape of a chapter follows the wrapped app's executive deck: a kicker
/// that says which chapter this is, the three key takeaways as numbered
/// panels, the three key terms as chips, the keyword tags, the tips, the
/// hints, and the spoken recap at the end.
private final class BriefingTextBuilder {

    struct Output {
        let string: NSAttributedString
        /// The range of each chapter's heading, in document order.
        let chapterRanges: [NSRange]
        /// The range of the thesis block, so the view can rule it.
        let thesisRange: NSRange?
        /// The panels to draw behind the text.
        let cards: [ReaderCard]
        /// The term chips.
        let chips: [ReaderChipInfo]
        /// The keyword tags.
        let keywords: [ReaderKeywordInfo]
        /// The ranges to rule underneath.
        let ruleRanges: [NSRange]
    }

    private let text = NSMutableAttributedString()
    private var cards: [ReaderCard] = []
    private var chips: [ReaderChipInfo] = []
    private var keywordInfos: [ReaderKeywordInfo] = []
    private var ruleRanges: [NSRange] = []

    // MARK: Type

    private static let bodyFont = Typography.reading()
    private static let thesisFont = NSFont.systemFont(ofSize: 19, weight: .semibold)
    private static let headingFont = NSFont.systemFont(ofSize: 11, weight: .bold)
    private static let chapterTitleFont = NSFont.systemFont(ofSize: 22, weight: .bold)
    private static let subheadingFont = NSFont.systemFont(ofSize: 11, weight: .bold)
    private static let captionFont = Typography.secondary()
    private static let chipFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let tagFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    private static let termFont = NSFont.systemFont(ofSize: 15, weight: .semibold)

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

        let total = briefing.chapters.count
        for (index, chapter) in briefing.chapters.enumerated() {
            builder.air(extra: 16)

            let kicker = builder.chapterKicker(number: index + 1, of: total, chapter: chapter)
            chapterRanges.append(kicker)
            builder.ruleRanges.append(kicker)

            builder.chapterTitle(chapter.title)
            builder.takeaways(chapter.takeaways)
            builder.keyTerms(chapter.keyTerms, chapter: index + 1)
            builder.keywords(chapter.keywords, chapter: index + 1)
            builder.glossary(chapter.glossary)
            builder.tips(chapter.tips)
            builder.hints(chapter.hints)
            builder.audio(chapter.audioScript)
        }

        return Output(string: builder.text,
                      chapterRanges: chapterRanges,
                      thesisRange: thesisRange,
                      cards: builder.cards,
                      chips: builder.chips,
                      keywords: builder.keywordInfos,
                      ruleRanges: builder.ruleRanges)
    }

    // MARK: Pieces

    /// A little air above a heading. Paragraph styles have no space-before,
    /// so the gap is an empty line with a small font.
    private func air(extra: CGFloat = 0) {
        append("", font: .systemFont(ofSize: 10 + extra / 4), colour: .clear, style: Self.airStyle())
    }

    private func heading(_ title: String) {
        append(title.uppercased(), font: Self.headingFont, colour: Palette.accent, style: Self.headingStyle())
    }

    private func subheading(_ title: String, hint: String? = nil) {
        append(title.uppercased(), font: Self.subheadingFont, colour: Palette.teal,
               style: Self.subheadingStyle(), endsParagraph: false)
        if let hint {
            append("   \(hint)", font: Self.captionFont, colour: .tertiaryLabelColor,
                   style: Self.subheadingStyle(), endsParagraph: false)
        }
        endParagraph(font: Self.subheadingFont, style: Self.subheadingStyle())
    }

    private func paragraph(_ body: String) {
        append(body, font: Self.bodyFont, colour: .labelColor, style: Self.bodyStyle())
    }

    /// The thesis: a pull quote, set apart by an indent and a rule.
    private func thesis(_ body: String) -> NSRange {
        append(body, font: Self.thesisFont, colour: .secondaryLabelColor, style: Self.thesisStyle())
    }

    /// The line that says which chapter this is.
    ///
    /// "CHAPTER 07 OF 39 · pp. Chapter 15 · ~1,240 words" — the same
    /// information the wrapped app put on its slide, and the thing the
    /// reader needs when they come back to a place they left.
    private func chapterKicker(number: Int, of total: Int, chapter: BriefingChapter) -> NSRange {
        let start = text.length
        append("CHAPTER \(String(format: "%02d", number)) OF \(total)",
               font: Self.headingFont, colour: Palette.accent, style: Self.kickerStyle(), endsParagraph: false)

        var detail: [String] = []
        if !chapter.pageRange.isEmpty { detail.append(Self.pageRange(chapter.pageRange)) }
        if chapter.wordCount > 0 { detail.append("~\(chapter.wordCount.formatted()) words") }
        if !detail.isEmpty {
            append("   ·   \(detail.joined(separator: "  ·  "))",
                   font: Self.captionFont, colour: .tertiaryLabelColor, style: Self.kickerStyle(), endsParagraph: false)
        }

        endParagraph(font: Self.captionFont, style: Self.kickerStyle())
        return NSRange(location: start, length: text.length - start)
    }

    /// The chapter's own title, set large the way the deck set it.
    private func chapterTitle(_ title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        append(clean, font: Self.chapterTitleFont, colour: .labelColor, style: Self.chapterTitleStyle())
    }

    /// The three key takeaways, each on its own numbered panel.
    private func takeaways(_ items: [String]) {
        let usable = items.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !usable.isEmpty else { return }

        for (index, item) in usable.prefix(3).enumerated() {
            let start = text.length
            append(item, font: Self.bodyFont, colour: .labelColor,
                   style: Self.takeawayStyle(), endsParagraph: false)
            let end = text.length
            endParagraph(font: Self.bodyFont, style: Self.takeawayStyle())
            cards.append(ReaderCard(kind: .takeaway,
                                     range: NSRange(location: start, length: end - start),
                                     badge: index + 1))
        }
    }

    /// The three key terms, as chips.
    ///
    /// A chip is one word long. "Personal Day Card" is shown as "Personal",
    /// and the pop-up gives the rest of the meaning — a chip long enough to
    /// wrap takes the reader's eye off the page it is on.
    private func keyTerms(_ entries: [BriefingGlossary], chapter: Int) {
        let usable = entries.filter { !$0.term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !usable.isEmpty else { return }

        subheading("Key terms", hint: "hover a chip for the full meaning")
        for (index, entry) in usable.prefix(3).enumerated() {
            if index > 0 {
                append("   ", font: Self.chipFont, colour: .clear, style: Self.chipStyle(), endsParagraph: false)
            }
            let word = ReaderChipWord.forTerm(entry.term)
            let start = text.length
            append(" \(word) ", font: Self.chipFont, colour: Palette.accent,
                   style: Self.chipStyle(), endsParagraph: false,
                   background: Palette.wash(Palette.accent, amount: 0.14))
            let range = NSRange(location: start, length: text.length - start)
            chips.append(ReaderChipInfo(term: entry.term,
                                         word: word,
                                         definition: entry.definition,
                                         range: range,
                                         chapter: chapter))
        }
        endParagraph(font: Self.chipFont, style: Self.chipStyle())
    }

    /// The short tags that say what the chapter covers.
    ///
    /// A tag is a link: clicking it shows every chapter that uses the word,
    /// and the key terms that talk about it.
    private func keywords(_ tags: [String], chapter: Int) {
        let usable = tags.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !usable.isEmpty else { return }

        subheading("Keywords", hint: "click a tag to follow it")
        for (index, tag) in usable.prefix(6).enumerated() {
            if index > 0 {
                append(" ", font: Self.tagFont, colour: .clear, style: Self.tagStyle(), endsParagraph: false)
            }
            let start = text.length
            append("\(tag) ", font: Self.tagFont, colour: Palette.blue,
                   style: Self.tagStyle(), endsParagraph: false,
                   background: Palette.wash(Palette.blue, amount: 0.11))
            let range = NSRange(location: start, length: text.length - start)
            keywordInfos.append(ReaderKeywordInfo(keyword: tag, range: range, chapter: chapter))
        }
        endParagraph(font: Self.tagFont, style: Self.tagStyle())
    }

    /// The vocabulary of the chapter: a term and what it means.
    private func glossary(_ entries: [BriefingGlossary]) {
        let usable = entries.filter { !$0.term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !usable.isEmpty else { return }

        subheading("Glossary")
        for entry in usable.prefix(5) {
            append(entry.term, font: Self.termFont, colour: .labelColor,
                   style: Self.glossaryStyle(), endsParagraph: false)
            append("  ", font: Self.bodyFont, colour: .secondaryLabelColor,
                   style: Self.glossaryStyle(), endsParagraph: false)
            append(entry.definition, font: Self.bodyFont, colour: .secondaryLabelColor,
                   style: Self.glossaryStyle())
        }
    }

    /// What the reader could do with this chapter.
    private func tips(_ items: [String]) {
        let usable = items.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !usable.isEmpty else { return }

        subheading("Tips")
        let start = text.length
        for item in usable.prefix(3) {
            append("•", font: Self.bodyFont, colour: Palette.green,
                   style: Self.tipStyle(), endsParagraph: false)
            append("   \(item)", font: Self.bodyFont, colour: .labelColor, style: Self.tipStyle())
        }
        cards.append(ReaderCard(kind: .tips,
                                 range: NSRange(location: start, length: text.length - start)))
    }

    /// What is worth noticing in this chapter.
    private func hints(_ items: [String]) {
        let usable = items.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !usable.isEmpty else { return }

        subheading("Hints")
        let start = text.length
        for item in usable.prefix(3) {
            append("◆", font: NSFont.systemFont(ofSize: 11), colour: Palette.gold,
                   style: Self.tipStyle(), endsParagraph: false)
            append("   \(item)", font: Self.bodyFont, colour: .labelColor, style: Self.tipStyle())
        }
        cards.append(ReaderCard(kind: .hints,
                                 range: NSRange(location: start, length: text.length - start)))
    }

    /// The spoken 60-second recap.
    private func audio(_ script: String) {
        let clean = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        subheading("60-second recap")
        let start = text.length
        append("“\(clean)”", font: Self.bodyFont, colour: .secondaryLabelColor,
               style: Self.quoteStyle())
        cards.append(ReaderCard(kind: .audio,
                                 range: NSRange(location: start, length: text.length - start)))
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
                        endsParagraph: Bool = true,
                        background: NSColor? = nil) -> NSRange {
        let range = NSRange(location: text.length, length: (string as NSString).length)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: colour,
            .paragraphStyle: style
        ]
        if let background {
            attributes[.backgroundColor] = background
        }
        text.append(NSAttributedString(string: string, attributes: attributes))
        if endsParagraph {
            endParagraph(font: font, style: style)
        }
        return range
    }

    /// End the current paragraph.
    private func endParagraph(font: NSFont, style: NSParagraphStyle) {
        text.append(NSAttributedString(string: "\n", attributes: [
            .font: font,
            .foregroundColor: NSColor.clear,
            .paragraphStyle: style
        ]))
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

    /// The kicker: one line, with room under it for the hairline.
    private static func kickerStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.0
        style.paragraphSpacing = 10
        return style
    }

    private static func chapterTitleStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.lineHeightMultiple = 1.15
        style.paragraphSpacing = 14
        return style
    }

    /// A takeaway: the text sits clear of the badge in the gutter, and
    /// every line lines up with the first.
    private static func takeawayStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5
        style.lineHeightMultiple = 1.3
        style.paragraphSpacing = 9
        style.headIndent = 34
        style.firstLineHeadIndent = 34
        return style
    }

    private static func chipStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 8
        style.lineHeightMultiple = 1.1
        style.paragraphSpacing = 10
        return style
    }

    private static func tagStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 7
        style.lineHeightMultiple = 1.1
        style.paragraphSpacing = 10
        return style
    }

    private static func tipStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        style.lineHeightMultiple = 1.3
        style.paragraphSpacing = 5
        style.headIndent = 20
        style.firstLineHeadIndent = -20
        return style
    }

    private static func quoteStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5
        style.lineHeightMultiple = 1.3
        style.paragraphSpacing = 8
        style.headIndent = 14
        style.firstLineHeadIndent = 0
        return style
    }
}
