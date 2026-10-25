import Cocoa
import Foundation

// MARK: - The overview band

/// The band at the top of the reader: what the book is, how big it is, and
/// the words it keeps coming back to.
///
/// A briefing is a long scroll, and the numbers that describe the book are
/// at the top of it — but the reader arrives in the middle of a chapter, not
/// at the beginning. Putting the numbers in the reader's own header means
/// they are there whichever chapter is on screen.
final class ReaderOverviewView: NSView {

    /// The reader clicked a word in the cloud.
    var onWord: ((ReaderWord) -> Void)?

    private let statsStack = NSStackView()
    private let rule = NSBox()
    private let cloudLabel = NSTextField(labelWithString: "MOST DISCUSSED")
    private let cloudView = ReaderWordCloudView()

    /// The height the band takes.
    ///
    /// The row of figures, a hairline, and three lines of word cloud.
    static let height: CGFloat = 136

    /// The height the band wants.
    private var heightConstraint: NSLayoutConstraint?

    /// Change the band's height.
    ///
    /// A hidden view still takes up room in Auto Layout, so the band is
    /// collapsed rather than merely hidden.
    func setHeight(_ height: CGFloat) {
        heightConstraint?.constant = height
    }

    override init(frame frameRect: NSRect) {
        statsStack.translatesAutoresizingMaskIntoConstraints = false
        rule.translatesAutoresizingMaskIntoConstraints = false
        cloudLabel.translatesAutoresizingMaskIntoConstraints = false
        cloudView.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = 10

        statsStack.orientation = .horizontal
        statsStack.alignment = .top
        statsStack.distribution = .fill
        statsStack.spacing = 0

        rule.boxType = .separator

        cloudLabel.font = .systemFont(ofSize: 9, weight: .bold)
        cloudLabel.textColor = .tertiaryLabelColor
        cloudLabel.setContentHuggingPriority(.required, for: .horizontal)

        cloudView.onWord = { [weak self] word in
            self?.onWord?(word)
        }

        addSubview(statsStack)
        addSubview(rule)
        addSubview(cloudLabel)
        addSubview(cloudView)

        statsStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14).isActive = true
        statsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14).isActive = true
        statsStack.topAnchor.constraint(equalTo: topAnchor, constant: 12).isActive = true

        rule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14).isActive = true
        rule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14).isActive = true
        rule.topAnchor.constraint(equalTo: statsStack.bottomAnchor, constant: 10).isActive = true
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true

        cloudLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14).isActive = true
        cloudLabel.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 10).isActive = true

        cloudView.leadingAnchor.constraint(equalTo: cloudLabel.trailingAnchor, constant: 14).isActive = true
        cloudView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14).isActive = true
        cloudView.topAnchor.constraint(equalTo: cloudLabel.topAnchor, constant: 1).isActive = true
        // Three lines of cloud. The words are laid out in rows of twenty
        // points, so a shorter band would draw its last line outside itself.
        cloudView.heightAnchor.constraint(equalToConstant: 60).isActive = true

        let height = heightAnchor.constraint(equalToConstant: Self.height)
        heightConstraint = height
        height.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = resolvedCGColor(NSColor.controlBackgroundColor)
        layer?.borderColor = resolvedCGColor(NSColor.separatorColor)
        layer?.borderWidth = 1
    }

    /// Fill the band in.
    func show(briefing: Briefing, vocabulary: ReaderVocabulary) {
        for view in statsStack.arrangedSubviews {
            statsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        // The band's numbers are the book's *vocabulary*, not its size: the
        // chips under the title already say how long the book is.
        let words = vocabulary.topWords(limit: 26)
        let top = words.first
        let topCaption: String
        if let top {
            let chapters = vocabulary.chapterCount(for: top.text)
            topCaption = chapters > 1 ? "TOP TERM · \(chapters) CHAPTERS" : "TOP TERM"
        } else {
            topCaption = "TOP TERM"
        }

        let stats: [(String, String, NSColor)] = [
            ("\(vocabulary.keyTerms.count)", "KEY TERMS", Palette.accent),
            ("\(vocabulary.keywords.count)", "KEYWORDS", Palette.gold),
            (top?.text ?? "—", topCaption, Palette.teal)
        ]

        for (value, caption, colour) in stats {
            let tile = ReaderStatTile(value: value, caption: caption, colour: colour)
            statsStack.addArrangedSubview(tile)
            tile.widthAnchor.constraint(equalTo: statsStack.widthAnchor,
                                        multiplier: 1.0 / CGFloat(stats.count)).isActive = true
        }

        cloudView.setWords(words)
        needsDisplay = true
    }

    /// Empty the band.
    func clear() {
        for view in statsStack.arrangedSubviews {
            statsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        cloudView.setWords([])
    }

    private static func grouped(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }

    private static func readingTime(_ minutes: Int) -> String {
        guard minutes > 0 else { return "—" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        if rest == 0 { return "\(hours) hr" }
        return "\(hours) hr \(rest) min"
    }
}

// MARK: - A number in the overview

/// One figure with its label under it.
final class ReaderStatTile: NSView {

    private let valueLabel = NSTextField(labelWithString: "")
    private let captionLabel = NSTextField(labelWithString: "")

    init(value: String, caption: String, colour: NSColor) {
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        captionLabel.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false

        valueLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        valueLabel.textColor = colour
        valueLabel.lineBreakMode = .byTruncatingTail

        captionLabel.font = .systemFont(ofSize: 9, weight: .bold)
        captionLabel.textColor = .tertiaryLabelColor
        captionLabel.lineBreakMode = .byTruncatingTail

        valueLabel.stringValue = value
        captionLabel.stringValue = caption

        addSubview(valueLabel)
        addSubview(captionLabel)

        valueLabel.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
        valueLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor).isActive = true
        valueLabel.topAnchor.constraint(equalTo: topAnchor).isActive = true

        captionLabel.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
        captionLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor).isActive = true
        captionLabel.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 1).isActive = true
        captionLabel.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - The word cloud

/// The words a book keeps coming back to, sized by how much it says about
/// them.
///
/// The cloud is not decoration: every word in it is a way into the book.
/// Clicking one takes the reader to the first chapter that uses it.
final class ReaderWordCloudView: NSView {

    /// The reader clicked a word.
    var onWord: ((ReaderWord) -> Void)?

    private var words: [ReaderWord] = []
    private var placed: [(word: ReaderWord, rect: NSRect, font: NSFont)] = []
    private var hovered: Int?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    /// The cloud is laid out top to bottom, like text.
    override var isFlipped: Bool { true }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The words on show.
    func setWords(_ words: [ReaderWord]) {
        self.words = words
        relayout()
    }

    // MARK: Layout

    private func relayout() {
        placed = []
        guard !words.isEmpty, bounds.width > 0 else {
            needsDisplay = true
            return
        }

        let highest = max(1, words.first?.weight ?? 1)
        let gap: CGFloat = 11
        let lineHeight: CGFloat = 20

        var x: CGFloat = 0
        var y: CGFloat = 0

        for word in words {
            let ratio = min(1, max(0.16, Double(word.weight) / Double(highest)))
            let size = 10.5 + ratio * 8.5
            let font = NSFont.systemFont(ofSize: size,
                                         weight: ratio > 0.75 ? .semibold : .regular)
            let text = word.text as NSString
            let width = text.size(withAttributes: [.font: font]).width
            let height = text.size(withAttributes: [.font: font]).height

            if x > 0, x + width > bounds.width {
                x = 0
                y += lineHeight
            }
            // Three lines is as much as the band has room for.
            if y > lineHeight * 2 { break }

            placed.append((word, NSRect(x: x, y: y, width: width, height: height), font))
            x += width + gap
        }

        updateTrackingAreas()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        relayout()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        for (index, item) in placed.enumerated() {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: item.font,
                .foregroundColor: colour(for: item.word, hovered: hovered == index)
            ]
            (item.word.text as NSString).draw(in: item.rect, withAttributes: attributes)
        }
    }

    /// The colour a word is drawn in.
    ///
    /// The words the book is most about are the loudest; the rest fall away
    /// into the background so the cloud has a shape.
    private func colour(for word: ReaderWord, hovered: Bool) -> NSColor {
        if hovered { return Palette.accent }
        let highest = max(1, words.first?.weight ?? 1)
        let ratio = Double(word.weight) / Double(highest)
        if ratio > 0.7 { return Palette.accent }
        if ratio > 0.4 { return Palette.blue }
        if ratio > 0.22 { return Palette.teal }
        return .secondaryLabelColor
    }

    // MARK: The mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        for (index, item) in placed.enumerated() {
            addTrackingArea(NSTrackingArea(rect: item.rect.insetBy(dx: -3, dy: -2),
                                           options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                           owner: self,
                                           userInfo: ["index": index]))
        }
    }

    override func mouseEntered(with event: NSEvent) {
        guard let index = event.trackingArea?.userInfo?["index"] as? Int, index < placed.count else { return }
        hovered = index
        NSCursor.pointingHand.set()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard hovered != nil else { return }
        hovered = nil
        NSCursor.arrow.set()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for item in placed where item.rect.contains(point) {
            onWord?(item.word)
            return
        }
    }
}
