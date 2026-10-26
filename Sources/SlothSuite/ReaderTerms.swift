import Cocoa
import Foundation

// MARK: - The book's vocabulary

/// A key term, and where it sits in the book.
struct ReaderKeyTerm {
    /// The full term, as the model wrote it.
    var name: String
    /// The one word the chip shows.
    var word: String
    var definition: String
    /// The chapter it belongs to, 1-based.
    var chapter: Int
    /// The characters the chip occupies.
    var range: NSRange
}

/// A keyword tag, and where it sits in the book.
struct ReaderKeyword {
    var name: String
    /// The chapter it belongs to, 1-based.
    var chapter: Int
    /// The characters the tag occupies.
    var range: NSRange
}

/// A word in the cloud, and where it can be found.
struct ReaderWord {
    var text: String
    /// How much of the book talks about it.
    var weight: Int
    /// The chapter it first appears in, 1-based.
    var chapter: Int
    /// The characters it occupies there.
    var range: NSRange
}

/// Everything the book says, indexed so a term can be found everywhere it
/// appears and linked to the other terms that talk about it.
///
/// The reader shows one chapter at a time, but a book's vocabulary is not
/// chapter-shaped: "ritual" turns up in nine chapters, and the key term
/// "Personal Day Card" is defined in terms of the "Daily Draw" practice.
/// Without an index, the reader can only see the chapter they are in. With
/// one, every term can be followed to the places it is used.
final class ReaderVocabulary {

    /// Every key term in the book, in document order.
    private(set) var keyTerms: [ReaderKeyTerm] = []

    /// Every keyword tag in the book, in document order.
    private(set) var keywords: [ReaderKeyword] = []

    /// The chapters a keyword appears in, in document order.
    private(set) var keywordChapters: [String: [Int]] = [:]

    /// The chapters a key term appears in.
    private(set) var termChapters: [String: [Int]] = [:]

    /// The key terms whose definition mentions a given term.
    ///
    /// Keyed by the normalised term. This is what links one key word to
    /// another: a term whose definition talks about "ritual" is about ritual
    /// in the same way the reader means it.
    private(set) var mentions: [String: [ReaderKeyTerm]] = [:]

    // MARK: Building

    /// Index a briefing's chips and keyword tags.
    func build(chips: [ReaderChipInfo], keywords: [ReaderKeywordInfo]) {
        keyTerms = chips.map {
            ReaderKeyTerm(name: $0.term,
                          word: $0.word,
                          definition: $0.definition,
                          chapter: $0.chapter,
                          range: $0.range)
        }
        self.keywords = keywords.map {
            ReaderKeyword(name: $0.keyword, chapter: $0.chapter, range: $0.range)
        }

        var keywordIndex: [String: [Int]] = [:]
        for keyword in self.keywords {
            let key = Self.normalise(keyword.name)
            guard !key.isEmpty else { continue }
            var list = keywordIndex[key] ?? []
            if list.last != keyword.chapter { list.append(keyword.chapter) }
            keywordIndex[key] = list
        }
        keywordChapters = keywordIndex

        var termIndex: [String: [Int]] = [:]
        for term in keyTerms {
            let key = Self.normalise(term.name)
            guard !key.isEmpty else { continue }
            var list = termIndex[key] ?? []
            if list.last != term.chapter { list.append(term.chapter) }
            termIndex[key] = list
        }
        termChapters = termIndex

        // Which key terms talk about which. A book of a few hundred terms is
        // small enough to compare every pair.
        var link: [String: [ReaderKeyTerm]] = [:]
        for term in keyTerms {
            let key = Self.normalise(term.name)
            guard !key.isEmpty else { continue }
            var found: [ReaderKeyTerm] = []
            for other in keyTerms where !(other.chapter == term.chapter && other.name == term.name) {
                if Self.definition(other.definition, mentions: term.name) {
                    found.append(other)
                }
            }
            link[key] = found
        }
        mentions = link
    }

    // MARK: Looking up

    /// The chapters a keyword appears in.
    func chapters(forKeyword name: String) -> [Int] {
        keywordChapters[Self.normalise(name)] ?? []
    }

    /// The chapters a key term appears in.
    func chapters(forTerm name: String) -> [Int] {
        termChapters[Self.normalise(name)] ?? []
    }

    /// The key terms whose definition talks about a term.
    func related(to term: ReaderKeyTerm) -> [ReaderKeyTerm] {
        mentions[Self.normalise(term.name)] ?? []
    }

    /// How many chapters a word appears in.
    func chapterCount(for word: String) -> Int {
        let key = Self.normalise(word)
        let terms = termChapters[key] ?? []
        let tags = keywordChapters[key] ?? []
        return Set(terms + tags).count
    }

    /// The key terms whose definition talks about a keyword.
    func terms(mentioning keyword: String) -> [ReaderKeyTerm] {
        keyTerms.filter { Self.definition($0.definition, mentions: keyword) }
    }

    /// The most-discussed words in the book.
    ///
    /// A key term counts for more than a keyword: the model chose it as the
    /// chapter's vocabulary, while a keyword is a tag that may be a synonym of
    /// something else. The cloud is about what the book is *about*, so the
    /// key terms lead.
    func topWords(limit: Int) -> [ReaderWord] {
        var weights: [String: Int] = [:]
        var display: [String: String] = [:]
        var places: [String: (chapter: Int, range: NSRange)] = [:]

        for term in keyTerms {
            let key = Self.normalise(term.name)
            guard !key.isEmpty else { continue }
            if display[key] == nil {
                display[key] = term.name
                places[key] = (term.chapter, term.range)
            }
            weights[key, default: 0] += 3
        }
        for keyword in keywords {
            let key = Self.normalise(keyword.name)
            guard !key.isEmpty else { continue }
            if display[key] == nil {
                display[key] = keyword.name
                places[key] = (keyword.chapter, keyword.range)
            }
            weights[key, default: 0] += 1
        }

        let ranked = weights.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return (display[lhs.key] ?? lhs.key) < (display[rhs.key] ?? rhs.key)
        }

        return ranked.prefix(limit).compactMap { entry in
            guard let place = places[entry.key] else { return nil }
            return ReaderWord(text: display[entry.key] ?? entry.key,
                              weight: entry.value,
                              chapter: place.chapter,
                              range: place.range)
        }
    }

    // MARK: Text

    /// The key used to compare two words.
    static func normalise(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// Does a definition talk about a term?
    ///
    /// Whole words only: "art" is not mentioned by a definition that says
    /// "cartography", and a link to the wrong term is worse than no link.
    static func definition(_ definition: String, mentions term: String) -> Bool {
        let needle = normalise(term)
        guard !needle.isEmpty, !definition.isEmpty else { return false }

        let words = normalise(definition)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return words.contains(needle)
    }
}

// MARK: - One word for a term

/// How a term is shown on a chip.
///
/// A chip is one word long. A term like "Personal Day Card" is three words
/// long and says much more, so the chip carries the first word and the
/// pop-up carries the rest.
enum ReaderChipWord {

    /// The one word a chip shows for a term.
    static func forTerm(_ term: String) -> String {
        let clean = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = clean.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
        guard let first = words.first else { return clean }

        // A leading article says nothing at all: "The Personal Day Card"
        // reads as "Personal".
        if words.count > 1, ["the", "a", "an"].contains(first.lowercased()) {
            return String(words[1])
        }
        return String(first)
    }
}

// MARK: - The term pop-up

/// Something the reader can go to from the pop-up.
struct ReaderTermJump {
    /// What the row says.
    var title: String
    /// The smaller line under it.
    var detail: String?
    /// What happens when it is clicked.
    var action: () -> Void
}

/// A group of jumps under a heading.
struct ReaderTermSection {
    var heading: String
    var rows: [ReaderTermJump]
}

/// The pop-up that explains a term.
///
/// The wrapped app put the explanation in a floating card above the chip it
/// belonged to. This is the same idea, drawn the way a native macOS window
/// draws it: the full term first, then what it means, then the places the
/// reader can go next.
final class ReaderTermPopUpView: NSView {

    /// The mouse came in.
    var onMouseEnter: (() -> Void)?
    /// The mouse went out.
    var onMouseExit: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let definitionLabel = NSTextField(wrappingLabelWithString: "")
    private let stack = NSStackView()

    /// The height the term takes.
    private var titleHeight: NSLayoutConstraint?
    /// The height the definition takes.
    private var definitionHeight: NSLayoutConstraint?

    /// The width the pop-up is laid out at.
    private static let width: CGFloat = 300

    override init(frame frameRect: NSRect) {
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        definitionLabel.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: frameRect)

        // The pop-up is sized by its own constraints, so it has to be
        // managed by Auto Layout: a view that is not has a frame of its own,
        // and a frame of its own is a frame of zero.
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = ReaderStyle.radius

        // The term is the headline. The system face, like the rest of the
        // suite: one type voice across every panel.
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 3

        definitionLabel.font = .systemFont(ofSize: 12)
        definitionLabel.textColor = .secondaryLabelColor
        definitionLabel.lineBreakMode = .byWordWrapping
        definitionLabel.maximumNumberOfLines = 8

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(definitionLabel)
        addSubview(stack)

        titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14).isActive = true
        titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14).isActive = true
        titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 13).isActive = true
        // A label whose text wraps has no height of its own, so its height
        // is worked out from the text and the width the pop-up is given.
        let title = titleLabel.heightAnchor.constraint(equalToConstant: 0)
        title.isActive = true
        titleHeight = title

        definitionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14).isActive = true
        definitionLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14).isActive = true
        definitionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 7).isActive = true
        let definition = definitionLabel.heightAnchor.constraint(equalToConstant: 0)
        definition.isActive = true
        definitionHeight = definition

        stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8).isActive = true
        stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8).isActive = true
        stack.topAnchor.constraint(equalTo: definitionLabel.bottomAnchor, constant: 10).isActive = true
        stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12).isActive = true

        widthAnchor.constraint(equalToConstant: Self.width).isActive = true

        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEnter?()
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExit?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = resolvedCGColor(NSColor.controlBackgroundColor)
        layer?.borderColor = resolvedCGColor(Palette.wash(Palette.accent, amount: 0.45))
        layer?.borderWidth = 1
    }

    /// Fill the pop-up in.
    func show(term: String, definition: String, sections: [ReaderTermSection]) {
        titleLabel.stringValue = term
        definitionLabel.stringValue = definition
        definitionLabel.isHidden = definition.isEmpty

        // The heights are worked out from the text, at the width the pop-up
        // is given.
        let inner = Self.width - 28
        titleHeight?.constant = ceil(titleLabel.sizeThatFits(
            NSSize(width: inner, height: CGFloat.greatestFiniteMagnitude)).height)
        definitionHeight?.constant = definition.isEmpty ? 0 : ceil(definitionLabel.sizeThatFits(
            NSSize(width: inner, height: CGFloat.greatestFiniteMagnitude)).height)

        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for section in sections where !section.rows.isEmpty {
            let heading = NSTextField(labelWithString: section.heading.uppercased())
            heading.font = .systemFont(ofSize: 9, weight: .bold)
            heading.textColor = .tertiaryLabelColor
            stack.addArrangedSubview(heading)

            for row in section.rows {
                let view = ReaderJumpRow(jump: row)
                stack.addArrangedSubview(view)
            }
        }

        // A pop-up with nothing in it but a term still has to be a sensible
        // size, so the width is fixed and the height comes from the content.
        layer?.backgroundColor = resolvedCGColor(NSColor.controlBackgroundColor)
        layer?.borderColor = resolvedCGColor(Palette.wash(Palette.accent, amount: 0.45))
        layer?.borderWidth = 1
        needsDisplay = true
    }
}

// MARK: - A row in the pop-up

/// One clickable destination in the pop-up.
final class ReaderJumpRow: NSView {

    private let jump: ReaderTermJump
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    private var isHovering = false {
        didSet { updateAppearance() }
    }

    init(jump: ReaderTermJump) {
        self.jump = jump

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 6

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = Palette.accent
        titleLabel.lineBreakMode = .byTruncatingTail

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail

        titleLabel.stringValue = jump.title
        detailLabel.stringValue = jump.detail ?? ""
        detailLabel.isHidden = (jump.detail ?? "").isEmpty

        addSubview(titleLabel)
        addSubview(detailLabel)

        titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8).isActive = true
        titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8).isActive = true
        titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4).isActive = true

        detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor).isActive = true
        detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor).isActive = true
        detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1).isActive = true
        detailLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5).isActive = true

        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil))
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        jump.action()
    }

    private func updateAppearance() {
        layer?.backgroundColor = isHovering
            ? resolvedCGColor(Palette.wash(Palette.accent, amount: 0.12))
            : nil
    }
}

// MARK: - A term as a pill

/// A term shown as a pill, which explains itself when the reader hovers it.
///
/// The reader's chips are drawn inside its text, so they cannot be views.
/// The chapters window has real views, and this is the same chip as a
/// control: one word long, the rest of the meaning in the pop-up.
final class ReaderTermChipView: NSView {

    /// The pointer came in.
    var onHover: ((ReaderTermChipView, NSRect) -> Void)?
    /// The pointer went out.
    var onLeave: (() -> Void)?
    /// The chip was clicked.
    var onClick: ((String) -> Void)?

    /// The full term.
    let term: String
    /// The one word on the chip.
    let word: String
    /// What the term means.
    let definition: String

    private let label = NSTextField(labelWithString: "")
    private let colour: NSColor
    private var isHovering = false {
        didSet { updateAppearance() }
    }

    init(term: String, definition: String, colour: NSColor = Palette.accent) {
        self.term = term
        self.word = ReaderChipWord.forTerm(term)
        self.definition = definition
        self.colour = colour

        label.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6

        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = colour
        label.stringValue = self.word
        // The label is placed by hand rather than by Auto Layout: a chip is
        // sometimes put in a stack and sometimes given a frame directly, and
        // a chip whose label is laid out by Auto Layout comes out empty when
        // the chip itself is not.
        label.translatesAutoresizingMaskIntoConstraints = true

        addSubview(label)

        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil))
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let size = label.intrinsicContentSize
        label.frame = NSRect(x: 7,
                             y: (bounds.height - size.height) / 2,
                             width: max(0, bounds.width - 14),
                             height: size.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        NSCursor.pointingHand.set()
        onHover?(self, bounds)
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        NSCursor.arrow.set()
        onLeave?()
    }

    override func mouseUp(with event: NSEvent) {
        // A chip in the rail is a way into the book, so a click on it means
        // something: take the reader to the term.
        onClick?(term)
    }

    private func updateAppearance() {
        layer?.backgroundColor = resolvedCGColor(
            Palette.wash(colour, amount: isHovering ? 0.22 : 0.13)
        )
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: label.intrinsicContentSize.width + 14, height: 20)
    }
}

// MARK: - The pop-up's controller

/// Shows the term pop-up, and takes it away again.
final class ReaderTermPopUpController {

    private let popover = NSPopover()
    private let content = ReaderTermPopUpView()
    private var hideWork: DispatchWorkItem?

    init() {
        popover.behavior = .transient
        popover.animates = false

        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller

        // The mouse can travel from the chip to the pop-up without the
        // pop-up vanishing on the way, so the hiding is delayed and the
        // pop-up itself cancels it.
        content.onMouseEnter = { [weak self] in
            self?.cancelHide()
        }
        content.onMouseExit = { [weak self] in
            self?.scheduleHide()
        }
    }

    /// Show the pop-up against a rectangle in `view`.
    func present(term: String,
                 definition: String,
                 sections: [ReaderTermSection],
                 relativeTo rect: NSRect,
                 of view: NSView) {
        cancelHide()
        content.show(term: term, definition: definition, sections: sections)
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }

    /// Take the pop-up away.
    func dismiss() {
        cancelHide()
        popover.performClose(nil)
    }

    /// The pop-up is up.
    var isShown: Bool { popover.isShown }

    /// The pop-up's own view, so it can be looked at without a pointer.
    var contentViewForInspection: NSView? { content }

    /// Hold off closing the pop-up.
    func cancelHide() {
        hideWork?.cancel()
        hideWork = nil
    }

    /// Close the pop-up shortly, unless the mouse is still on it.
    func scheduleHide(after delay: TimeInterval = 0.35) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.popover.performClose(nil)
            self?.hideWork = nil
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
