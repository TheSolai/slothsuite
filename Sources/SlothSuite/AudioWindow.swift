import Cocoa
import Foundation

/// The surface the audio window's chapters sit on.
///
/// A layer's background colour is resolved when it is set, so the window has
/// to be told when the system appearance changes — otherwise the cards keep
/// the colours of the appearance they were built in, and a white card with a
/// white title cannot be read.
private final class AudioContentView: NSView {

    /// Called when the system appearance changes.
    var onAppearanceChange: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = resolvedCGColor(NSColor.windowBackgroundColor)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = resolvedCGColor(NSColor.windowBackgroundColor)
        onAppearanceChange?()
    }
}

/// A pop-out window that puts every chapter and its spoken script on one
/// scrollable page.
///
/// The reader shows the briefing as prose. This shows the other half of it:
/// the chapter-by-chapter audio, with a play button for each one and a
/// button that reads the lot. It is a window rather than a panel because it
/// is meant to sit beside the reader while you listen.
final class AudioWindowController {
    static let shared = AudioWindowController()

    private var window: NSWindow?
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let chapterStack = NSStackView()
    private let playAllButton = NSButton(title: "Play everything", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)

    /// The briefing currently on show, so a chapter's play button knows what
    /// to speak.
    private var briefing: Briefing?

    /// The pop-up that explains a term.
    private let termPopUp = ReaderTermPopUpController()

    /// The chips that carry a colour, so they can be repainted after a
    /// light/dark switch.
    private var termChips: [ReaderTermChipView] = []

    private init() {}

    // MARK: - Showing

    /// Open the window for a briefing, or bring it forward if it is already
    /// open.
    func show(briefing: Briefing) {
        self.briefing = briefing

        if window == nil {
            buildWindow()
        }

        render(briefing: briefing)

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }

    /// The window's content view, so the interface can be inspected without
    /// screen recording permission.
    var contentViewForInspection: NSView? {
        window?.contentView
    }

    // MARK: - Window

    private func buildWindow() {
        // A real surface, so the headings and buttons have something to read
        // against. The surface repaints itself when the system appearance
        // changes.
        let content = AudioContentView(frame: NSRect(x: 0, y: 0, width: 760, height: 840))
        content.onAppearanceChange = { [weak self] in
            self?.refreshAppearance()
        }

        // Auto Layout positions these, so the autoresizing mask must not
        // fight it — a view with the mask on keeps its old frame and is
        // never moved by its constraints.
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = Typography.display()
        titleLabel.lineBreakMode = .byTruncatingTail

        subtitleLabel.font = Typography.secondary()
        subtitleLabel.textColor = .secondaryLabelColor

        playAllButton.target = self
        playAllButton.action = #selector(playAll)
        playAllButton.bezelStyle = .rounded
        playAllButton.controlSize = .large
        playAllButton.font = Typography.body(weight: .medium)
        playAllButton.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)
        playAllButton.imagePosition = .imageLeading
        playAllButton.contentTintColor = Palette.accent
        playAllButton.setColoredTitle("Play everything", color: Palette.accent,
                                      font: Typography.body(weight: .medium))
        playAllButton.imageHugsTitle = true

        stopButton.target = self
        stopButton.action = #selector(stop)
        stopButton.bezelStyle = .rounded
        stopButton.controlSize = .large
        stopButton.font = Typography.body(weight: .medium)
        stopButton.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
        stopButton.imagePosition = .imageLeading
        stopButton.imageHugsTitle = true

        // The header.
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSStackView(views: [playAllButton, stopButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        header.addSubview(titleLabel)
        header.addSubview(subtitleLabel)
        header.addSubview(buttonRow)

        titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor).isActive = true
        titleLabel.topAnchor.constraint(equalTo: header.topAnchor).isActive = true
        titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: buttonRow.leadingAnchor, constant: -20).isActive = true

        subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor).isActive = true
        subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4).isActive = true
        subtitleLabel.bottomAnchor.constraint(equalTo: header.bottomAnchor).isActive = true

        buttonRow.trailingAnchor.constraint(equalTo: header.trailingAnchor).isActive = true
        buttonRow.centerYAnchor.constraint(equalTo: header.centerYAnchor).isActive = true

        // The chapters.
        chapterStack.orientation = .vertical
        chapterStack.alignment = .leading
        chapterStack.spacing = 16
        chapterStack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.documentView = chapterStack
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(header)
        content.addSubview(scroll)

        header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28).isActive = true
        header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28).isActive = true
        header.topAnchor.constraint(equalTo: content.topAnchor, constant: 24).isActive = true

        scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28).isActive = true
        scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28).isActive = true
        scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 20).isActive = true
        scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24).isActive = true

        chapterStack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor).isActive = true
        chapterStack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor).isActive = true
        chapterStack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor).isActive = true
        chapterStack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 840),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = "Audio and chapters"
        window.contentView = content
        // Assigning a content view takes the window's size from the view's
        // frame, so the size is set again afterwards to be sure of it.
        window.setContentSize(NSSize(width: 760, height: 840))
        window.minSize = NSSize(width: 560, height: 480)
        window.center()
        self.window = window
    }

    // MARK: - Content

    private func render(briefing: Briefing) {
        titleLabel.stringValue = briefing.title

        let minutes = max(1, Int(ceil(Double(briefing.chapters.count) * 0.7)))
        subtitleLabel.stringValue = briefing.chapters.isEmpty
            ? "No chapters yet"
            : "\(briefing.chapters.count) chapter\(briefing.chapters.count == 1 ? "" : "s") · roughly \(minutes) min of audio"

        chapterStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // The old cards are gone; keeping them would repaint views that are
        // no longer on screen.
        chapterCards = []

        guard !briefing.chapters.isEmpty else {
            let empty = NSTextField(labelWithString: "This briefing has no chapters to read yet.")
            empty.font = Typography.body()
            empty.textColor = .secondaryLabelColor
            chapterStack.addArrangedSubview(empty)
            return
        }

        termChips = []
        termPopUp.dismiss()

        var cards: [(card: NSView, number: NSTextField, playButton: NSButton)] = []
        for (index, chapter) in briefing.chapters.enumerated() {
            // The card goes into the stack first: a constraint between the
            // card and the stack has no common ancestor until the card is
            // actually in it.
            let card = NSView()
            chapterStack.addArrangedSubview(card)
            let parts = configureCard(card, chapter: chapter, index: index)
            cards.append(parts)
        }
        chapterCards = cards
    }

    /// The parts of each chapter card that carry a colour.
    ///
    /// A layer's background colour is resolved when it is set, so a card
    /// built in the light appearance keeps its white background after the
    /// user switches to dark — and the white title with it.
    private var chapterCards: [(card: NSView, number: NSTextField, playButton: NSButton)] = []

    /// Re-apply every colour that was resolved when the window was built.
    ///
    /// A layer's background colour is resolved at the moment it is set, so
    /// after the user switches macOS between light and dark the cards keep
    /// the colours of the appearance they were built in.
    private func refreshAppearance() {
        window?.contentView?.layer?.backgroundColor =
            window?.contentView?.resolvedCGColor(NSColor.windowBackgroundColor)
        for entry in chapterCards {
            entry.card.layer?.backgroundColor = entry.card.resolvedCGColor(NSColor.controlBackgroundColor)
            entry.card.layer?.borderColor = entry.card.resolvedCGColor(NSColor.separatorColor)
            entry.number.layer?.backgroundColor =
                entry.number.resolvedCGColor(Palette.wash(Palette.accent, amount: 0.16))
            entry.playButton.contentTintColor = Palette.accent
            entry.playButton.setColoredTitle("Play", color: Palette.accent,
                                             font: Typography.body(weight: .medium))
        }
        for chip in termChips {
            chip.needsDisplay = true
        }
    }

    @discardableResult
    private func configureCard(_ card: NSView,
                               chapter: BriefingChapter,
                               index: Int) -> (card: NSView, number: NSTextField, playButton: NSButton) {
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.backgroundColor = card.resolvedCGColor(NSColor.controlBackgroundColor)
        card.layer?.borderWidth = 1
        card.layer?.borderColor = card.resolvedCGColor(NSColor.separatorColor)
        card.translatesAutoresizingMaskIntoConstraints = false

        let number = NSTextField(labelWithString: "\(index + 1)")
        number.font = Typography.caption(weight: .bold)
        number.textColor = Palette.accent
        number.alignment = .center
        number.wantsLayer = true
        number.layer?.cornerRadius = 9
        number.layer?.backgroundColor = number.resolvedCGColor(Palette.wash(Palette.accent, amount: 0.16))
        number.translatesAutoresizingMaskIntoConstraints = false

        // The chapter's name in full. A chapter called "The Labours of Men
        // of Genius, However Erroneously Directed, Scare Us" is a name, and
        // a reader who cannot see it cannot find the chapter again.
        let name = NSTextField(wrappingLabelWithString: chapter.title.isEmpty
                                ? "Chapter \(index + 1)"
                                : chapter.title)
        name.font = Typography.title()
        name.lineBreakMode = .byTruncatingTail
        name.maximumNumberOfLines = 3
        name.cell?.truncatesLastVisibleLine = true
        name.setContentCompressionResistancePriority(.required, for: .vertical)

        var details: [String] = []
        if !chapter.pageRange.isEmpty { details.append(chapter.pageRange) }
        if chapter.wordCount > 0 { details.append("\(chapter.wordCount.formatted()) words") }
        let pages = NSTextField(labelWithString: details.joined(separator: "  ·  "))
        pages.font = Typography.caption()
        pages.textColor = Palette.teal

        let playButton = NSButton(title: "Play", target: self, action: #selector(playChapter(_:)))
        playButton.bezelStyle = .rounded
        playButton.controlSize = .regular
        playButton.font = Typography.body(weight: .medium)
        playButton.image = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: nil)
        playButton.imagePosition = .imageLeading
        playButton.contentTintColor = Palette.accent
        playButton.setColoredTitle("Play", color: Palette.accent,
                                   font: Typography.body(weight: .medium))
        playButton.imageHugsTitle = true
        playButton.tag = index
        playButton.setContentHuggingPriority(.required, for: .horizontal)

        // The card's labels used to live in a stack, which took their
        // autoresizing mask away for them. They are direct subviews now, so
        // each one hands it over itself — a view that keeps the mask is
        // never moved by its constraints, and nothing is logged when that
        // happens.
        name.translatesAutoresizingMaskIntoConstraints = false
        pages.translatesAutoresizingMaskIntoConstraints = false
        playButton.translatesAutoresizingMaskIntoConstraints = false

        // The spoken script, in full. This is the thing the window exists
        // for, so it is shown properly rather than truncated.
        let script = NSTextField(wrappingLabelWithString: chapter.audioScript.isEmpty
                                 ? chapter.spokenText
                                 : chapter.audioScript)
        script.font = Typography.body()
        script.textColor = .secondaryLabelColor
        script.alignment = .left
        script.translatesAutoresizingMaskIntoConstraints = false
        script.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        // The script is a wrapping label, so its natural width is the whole
        // unwrapped line — thousands of points. Without this the label pushes
        // the card, the stack and the window out to that width.
        script.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        script.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // The chapter's key terms, as chips. One word each; the pop-up gives
        // the rest of the meaning. A chapter list that only lists names
        // makes the reader open every chapter to find out what is in it.
        let chipsStack = NSStackView()
        chipsStack.orientation = .horizontal
        chipsStack.spacing = 6
        chipsStack.alignment = .centerY
        chipsStack.translatesAutoresizingMaskIntoConstraints = false
        chipsStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for entry in chapter.keyTerms.prefix(4) {
            let chip = ReaderTermChipView(term: entry.term, definition: entry.definition)
            chip.onHover = { [weak self] view, rect in
                self?.showTerm(view, rect)
            }
            chip.onLeave = { [weak self] in
                self?.termPopUp.scheduleHide()
            }
            chipsStack.addArrangedSubview(chip)
            termChips.append(chip)
        }
        chipsStack.isHidden = chipsStack.arrangedSubviews.isEmpty

        card.addSubview(number)
        card.addSubview(name)
        card.addSubview(pages)
        card.addSubview(playButton)
        card.addSubview(chipsStack)
        card.addSubview(script)

        number.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16).isActive = true
        number.topAnchor.constraint(equalTo: card.topAnchor, constant: 15).isActive = true
        number.widthAnchor.constraint(equalToConstant: 20).isActive = true
        number.heightAnchor.constraint(equalToConstant: 20).isActive = true

        name.leadingAnchor.constraint(equalTo: number.trailingAnchor, constant: 10).isActive = true
        name.topAnchor.constraint(equalTo: card.topAnchor, constant: 13).isActive = true
        name.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16).isActive = true

        pages.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16).isActive = true
        pages.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 6).isActive = true
        pages.trailingAnchor.constraint(lessThanOrEqualTo: playButton.leadingAnchor, constant: -12).isActive = true

        playButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16).isActive = true
        playButton.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2).isActive = true

        chipsStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16).isActive = true
        chipsStack.topAnchor.constraint(equalTo: pages.bottomAnchor, constant: 10).isActive = true
        chipsStack.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -16).isActive = true

        script.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16).isActive = true
        script.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16).isActive = true
        script.topAnchor.constraint(equalTo: chipsStack.bottomAnchor, constant: 12).isActive = true
        script.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16).isActive = true

        // The card is as wide as the page, so the script has a proper measure
        // to wrap in instead of being squeezed to nothing.
        card.widthAnchor.constraint(equalTo: chapterStack.widthAnchor).isActive = true

        return (card, number, playButton)
    }

    // MARK: - The term pop-up

    /// Explain a term, in the pop-up above the chip it belongs to.
    private func showTerm(_ chip: ReaderTermChipView, _ rect: NSRect) {
        termPopUp.present(term: chip.term,
                          definition: chip.definition,
                          sections: [],
                          relativeTo: rect,
                          of: chip)
    }

    // MARK: - Playing

    @objc private func playChapter(_ sender: NSButton) {
        guard let briefing else { return }
        let index = sender.tag
        guard briefing.chapters.indices.contains(index) else { return }

        let chapter = briefing.chapters[index]
        let text = chapter.audioScript.isEmpty ? chapter.spokenText : chapter.audioScript
        AudioPlayer.shared.speak(text, label: "Chapter \(index + 1)")
    }

    @objc private func playAll() {
        guard let briefing else { return }
        let texts = briefing.chapters.map { $0.audioScript.isEmpty ? $0.spokenText : $0.audioScript }
        let labels = briefing.chapters.enumerated().map { "Chapter \($0.offset + 1)" }
        AudioPlayer.shared.speakAll(texts, labels: labels)
    }

    @objc private func stop() {
        AudioPlayer.shared.stop()
    }
}
