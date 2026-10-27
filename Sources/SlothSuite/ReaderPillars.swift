import Cocoa
import Foundation

// MARK: - The three pillars

/// The three pillars of the reading experience, in the deck's words.
///
/// The wrapped app's executive deck opened with three cards: the rule of
/// three, the interactive glossary and the spoken recap. The native reader
/// has the same three things, so it says the same three things — but the
/// cards are live: each one shows the chapter the reader is actually in.
enum ReaderPillar {
    case principle
    case vocabulary
    case sound

    /// The deck's small label for the card.
    var kicker: String {
        switch self {
        case .principle: return "01 · PRINCIPLE"
        case .vocabulary: return "02 · VOCABULARY"
        case .sound: return "03 · SOUND"
        }
    }

    /// The deck's heading for the card.
    var title: String {
        switch self {
        case .principle: return "Exactly 3 High-Impact Takeaways"
        case .vocabulary: return "Interactive Technical Glossary"
        case .sound: return "60-Second Read-Aloud Conversational Recap"
        }
    }

    /// The deck's line of copy for the card.
    ///
    /// The sound card says the Mac's own voice rather than the cloud one:
    /// the suite is offline, and promising a fallback it does not have would
    /// be a lie told in a footnote.
    var copy: String {
        switch self {
        case .principle:
            return "No wall-of-text fatigue. Every single chapter is strictly constrained to three decisive conceptual breakthroughs with verified empirical proofs."
        case .vocabulary:
            return "Dense mathematical notation and specialized jargon turn into interactive hover chips with in-situ definitions, eliminating tab-switching friction."
        case .sound:
            return "Reinforce comprehension through dual-coding. Listen to sixty-second executive recaps spoken by your Mac's own voice — no key, no network."
        }
    }

    /// The colour the card is drawn in.
    ///
    /// The deck used cyan for the principle, green for the vocabulary and
    /// gold for the sound; these are the same three colours in the suite's
    /// own palette.
    var accent: NSColor {
        switch self {
        case .principle: return Palette.teal
        case .vocabulary: return Palette.green
        case .sound: return Palette.gold
        }
    }
}

// MARK: - The rail

/// The rail beside the reader's text.
///
/// The reader had a third of its width empty on both sides of the column and
/// nothing on the right but margin. The rail fills that space with the three
/// things the reader came for — the takeaways, the vocabulary and the
/// spoken recap — each one showing the chapter that is on screen.
final class ReaderPillarsView: NSView {

    /// The reader asked to hear the chapter on show.
    var onSpeakChapter: ((BriefingChapter) -> Void)?
    /// The reader wants the voice to stop.
    var onStopAudio: (() -> Void)?
    /// The reader clicked a takeaway and wants to be taken to it.
    var onTakeaway: ((Int) -> Void)?
    /// The reader clicked a term and wants to be taken to it.
    var onTerm: ((String) -> Void)?

    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let cards: [ReaderPillarCard]

    /// The width the rail is drawn at.
    ///
    /// The rail is a fixed width so that every line of text in it can be
    /// measured before it is drawn, which is what keeps the cards from
    /// having an ambiguous height.
    static let width: CGFloat = 264

    override init(frame frameRect: NSRect) {
        cards = [.principle, .vocabulary, .sound].map(ReaderPillarCard.init(pillar:))

        super.init(frame: frameRect)

        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        // An overlay scroller sits on top of the content rather than beside
        // it, so the cards keep the rail's full width.
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        scroll.documentView = stack
        addSubview(scroll)

        scroll.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
        scroll.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
        scroll.topAnchor.constraint(equalTo: topAnchor).isActive = true
        scroll.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true

        stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor).isActive = true
        stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor).isActive = true
        stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor).isActive = true
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true

        for card in cards {
            stack.addArrangedSubview(card)
            card.onTakeaway = { [weak self] index in
                self?.onTakeaway?(index)
            }
            card.onTerm = { [weak self] term in
                self?.onTerm?(term)
            }
            card.onSpeakChapter = { [weak self] chapter in
                self?.onSpeakChapter?(chapter)
            }
            card.onStopAudio = { [weak self] in
                self?.onStopAudio?()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Content

    /// Show the pillars for a chapter.
    func show(briefing: Briefing, chapter: Int) {
        let current: BriefingChapter? = {
            guard chapter > 0, chapter <= briefing.chapters.count else { return nil }
            return briefing.chapters[chapter - 1]
        }()

        cards[0].show(takeaways: current?.takeaways ?? [])
        cards[1].show(terms: current?.keyTerms ?? [])
        cards[2].show(chapter: current)
        needsDisplay = true
    }

    /// Empty the rail.
    func clear() {
        cards[0].show(takeaways: [])
        cards[1].show(terms: [])
        cards[2].show(chapter: nil)
    }

    /// The cards' headings, for the self-test.
    var pillarTitlesForTest: [String] { cards.map(\.pillar.title) }
}

// MARK: - One pillar

/// One of the three pillars: the deck's card, made live.
///
/// The card is laid out with explicit constraints rather than by hand. Every
/// piece of text in it is measured first, and the measurement becomes the
/// label's height — a label that wraps has no height of its own, and a
/// height that is not stated is a height that something else decides.
final class ReaderPillarCard: NSView {

    let pillar: ReaderPillar

    /// The reader clicked a takeaway.
    var onTakeaway: ((Int) -> Void)?
    /// The reader clicked a term.
    var onTerm: ((String) -> Void)?
    /// The reader asked to hear the chapter.
    var onSpeakChapter: ((BriefingChapter) -> Void)?
    /// The reader wants the voice to stop.
    var onStopAudio: (() -> Void)?

    private let kicker = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let copy = NSTextField(labelWithString: "")
    private let content = NSView()

    /// The badge in front of each takeaway.
    private var badges: [ReaderNumberBadge] = []
    /// The text of each takeaway.
    private var takeawayLabels: [NSTextField] = []
    /// The term chips.
    private var chips: [ReaderTermChipView] = []
    /// The play button for the spoken recap.
    private var playButton: NSButton?
    /// The line under the play button.
    private var soundNote: NSTextField?

    /// What the card is showing.
    private var takeaways: [String] = []
    private var terms: [BriefingGlossary] = []
    private var chapter: BriefingChapter?

    /// The height of the live part of the card.
    private var contentHeight: NSLayoutConstraint?

    /// The space inside the card.
    private static let padding: CGFloat = 16
    /// The room the badge takes at the start of a row.
    private static let badgeWidth: CGFloat = 28

    private static let kickerFont = NSFont.systemFont(ofSize: 9, weight: .bold)
    private static let titleFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    private static let copyFont = NSFont.systemFont(ofSize: 11, weight: .regular)
    private static let bodyFont = NSFont.systemFont(ofSize: 12, weight: .regular)
    private static let smallFont = NSFont.systemFont(ofSize: 10, weight: .regular)

    /// The width the text inside the card is laid out in.
    ///
    /// The rail is a fixed width, so this is a number rather than a guess —
    /// which is what lets the text be measured before it is drawn.
    private var innerWidth: CGFloat { ReaderPillarsView.width - Self.padding * 2 }

    init(pillar: ReaderPillar) {
        self.pillar = pillar

        super.init(frame: .zero)

        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        // The sound card's button becomes a stop button while the voice is
        // running, so it has to hear when that changes.
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(audioStateChanged),
                                               name: AudioPlayer.stateChanged,
                                               object: nil)

        kicker.font = Self.kickerFont
        kicker.textColor = pillar.accent
        kicker.stringValue = pillar.kicker

        title.font = Self.titleFont
        title.textColor = .labelColor
        title.stringValue = pillar.title

        copy.font = Self.copyFont
        copy.textColor = .secondaryLabelColor
        copy.stringValue = pillar.copy

        for label in [kicker, title, copy] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 0
            label.cell?.wraps = true
            label.cell?.isScrollable = false
        }

        content.translatesAutoresizingMaskIntoConstraints = false

        addSubview(kicker)
        addSubview(title)
        addSubview(copy)
        addSubview(content)

        // The rail is a fixed width, so the card is too.
        widthAnchor.constraint(equalToConstant: ReaderPillarsView.width).isActive = true

        kicker.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding).isActive = true
        kicker.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding).isActive = true
        kicker.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding).isActive = true
        kicker.heightAnchor.constraint(equalToConstant: Self.kickerFont.capHeight + 3).isActive = true

        title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding).isActive = true
        title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding).isActive = true
        title.topAnchor.constraint(equalTo: kicker.bottomAnchor, constant: 6).isActive = true
        title.heightAnchor.constraint(equalToConstant: Self.height(of: title, width: innerWidth)).isActive = true

        copy.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding).isActive = true
        copy.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding).isActive = true
        copy.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 7).isActive = true
        copy.heightAnchor.constraint(equalToConstant: Self.height(of: copy, width: innerWidth)).isActive = true

        content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding).isActive = true
        content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding).isActive = true
        content.topAnchor.constraint(equalTo: copy.bottomAnchor, constant: 15).isActive = true
        let height = content.heightAnchor.constraint(equalToConstant: 0)
        height.isActive = true
        contentHeight = height

        // The card is exactly as tall as what is in it.
        bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: Self.padding).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawReaderCard(bounds, accent: pillar.accent)
    }

    // MARK: Content

    /// Show the chapter's three takeaways.
    func show(takeaways items: [String]) {
        takeaways = items.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(3)
            .map { $0 }
        rebuildTakeawayRows()
    }

    /// Show the chapter's key terms.
    func show(terms items: [BriefingGlossary]) {
        terms = items.filter { !$0.term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(5)
            .map { $0 }
        rebuildChips()
    }

    /// Show the chapter that can be read aloud.
    func show(chapter item: BriefingChapter?) {
        chapter = item
        rebuildSound()
    }

    // MARK: Building the live part

    private func rebuildTakeawayRows() {
        for view in badges { view.removeFromSuperview() }
        for view in takeawayLabels { view.removeFromSuperview() }
        badges = []
        takeawayLabels = []

        var offset: CGFloat = 0
        let textWidth = innerWidth - Self.badgeWidth

        for (index, item) in takeaways.enumerated() {
            let badge = ReaderNumberBadge(number: index + 1, colour: pillar.accent)
            content.addSubview(badge)
            badge.translatesAutoresizingMaskIntoConstraints = false
            badge.leadingAnchor.constraint(equalTo: content.leadingAnchor).isActive = true
            badge.topAnchor.constraint(equalTo: content.topAnchor, constant: offset).isActive = true
            badge.widthAnchor.constraint(equalToConstant: 20).isActive = true
            badge.heightAnchor.constraint(equalToConstant: 20).isActive = true
            badges.append(badge)

            let label = NSTextField(labelWithString: item)
            label.font = Self.bodyFont
            label.textColor = .labelColor
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 0
            label.cell?.wraps = true
            label.cell?.isScrollable = false
            label.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(label)

            let height = Self.height(of: label, width: textWidth)
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.badgeWidth).isActive = true
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor).isActive = true
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: offset).isActive = true
            label.heightAnchor.constraint(equalToConstant: height).isActive = true
            takeawayLabels.append(label)

            offset += max(20, height) + 9
        }

        contentHeight?.constant = offset > 0 ? offset - 9 : 0
    }

    private func rebuildChips() {
        for view in chips { view.removeFromSuperview() }
        chips = []

        var offset: CGFloat = 0
        for entry in terms {
            let chip = ReaderTermChipView(term: entry.term,
                                          definition: entry.definition,
                                          colour: pillar.accent)
            chip.onClick = { [weak self] term in
                self?.onTerm?(term)
            }
            content.addSubview(chip)
            chip.translatesAutoresizingMaskIntoConstraints = false
            chip.leadingAnchor.constraint(equalTo: content.leadingAnchor).isActive = true
            chip.topAnchor.constraint(equalTo: content.topAnchor, constant: offset).isActive = true
            chip.widthAnchor.constraint(equalToConstant: chip.intrinsicContentSize.width).isActive = true
            chip.heightAnchor.constraint(equalToConstant: 20).isActive = true
            chips.append(chip)
            offset += 20 + 6
        }

        contentHeight?.constant = offset > 0 ? offset - 6 : 0
    }

    private func rebuildSound() {
        playButton?.removeFromSuperview()
        soundNote?.removeFromSuperview()
        playButton = nil
        soundNote = nil

        guard chapter != nil else {
            contentHeight?.constant = 0
            return
        }

        let button = NSButton(title: "Play this chapter", target: self, action: #selector(playPressed))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        button.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.contentTintColor = pillar.accent
        button.setColoredTitle("Play this chapter", color: pillar.accent,
                               font: NSFont.systemFont(ofSize: 11, weight: .medium))
        button.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(button)

        button.leadingAnchor.constraint(equalTo: content.leadingAnchor).isActive = true
        button.topAnchor.constraint(equalTo: content.topAnchor).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        playButton = button

        let note = NSTextField(labelWithString: "Sixty seconds, spoken by your Mac's own voice.")
        note.font = Self.smallFont
        note.textColor = .tertiaryLabelColor
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 0
        note.cell?.wraps = true
        note.cell?.isScrollable = false
        note.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(note)

        let noteHeight = Self.height(of: note, width: innerWidth)
        note.leadingAnchor.constraint(equalTo: content.leadingAnchor).isActive = true
        note.trailingAnchor.constraint(equalTo: content.trailingAnchor).isActive = true
        note.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 6).isActive = true
        note.heightAnchor.constraint(equalToConstant: noteHeight).isActive = true
        soundNote = note

        contentHeight?.constant = 24 + 6 + noteHeight
        updateSoundButton()
    }

    /// The button under the sound card is a play button until something is
    /// being read, and a stop button afterwards.
    ///
    /// The card is the one piece of the reader that is always about the
    /// voice, so the way to stop it belongs there.
    private func updateSoundButton() {
        guard let button = playButton else { return }
        let speaking = AudioPlayer.shared.isActive
        let title = speaking ? "Stop" : "Play this chapter"
        let symbol = speaking ? "stop.fill" : "speaker.wave.2.fill"
        button.title = title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.setColoredTitle(title, color: pillar.accent,
                               font: NSFont.systemFont(ofSize: 11, weight: .medium))
    }

    @objc private func audioStateChanged() {
        updateSoundButton()
    }

    @objc private func playPressed() {
        // The button says what it will do: stop the voice if there is one,
        // otherwise read this chapter.
        if AudioPlayer.shared.isActive {
            onStopAudio?()
            return
        }
        guard let chapter else { return }
        onSpeakChapter?(chapter)
    }

    // MARK: Measuring

    /// The height a label needs for its text at a given width.
    ///
    /// The label is asked, rather than the text being measured separately: a
    /// label knows how it sets its own lines, and measuring it a second way
    /// gives a slightly different answer — and the difference shows up as a
    /// clipped last line.
    private static func height(of label: NSTextField, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        let size = label.sizeThatFits(NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        return ceil(size.height)
    }

}
