import Cocoa

/// The review desk: spaced repetition over the user's own notes.
///
/// A learning suite that collects notes but never asks you to remember them
/// is only half a learning suite. The notes are the material — each one
/// becomes a card, and the schedule decides when it comes back.
///
/// The schedule is deliberately simple. A note you remembered comes back
/// after a day, then three, then a week, then a fortnight, then a month. A
/// note you forgot comes back in ten minutes, so it is still there before
/// you have closed the app.
final class ReviewView: NSView {

    /// Called with the note's id and whether it was remembered.
    var onRate: ((String, Bool) -> Void)?

    /// Called when the user wants to open the note itself.
    var onOpenNote: ((StudyNote) -> Void)?

    /// Called when the user wants to go back to the document.
    var onOpenDocument: ((StudyNote) -> Void)?

    /// How wide the card is. A review prompt is read at a glance, so it gets
    /// a comfortable measure rather than the full width of the window.
    private static let cardWidth: CGFloat = 620

    /// How tall the card is. It is a flashcard: the frame stays the same
    /// whatever the note says, so the desk does not jump about.
    private static let cardHeight: CGFloat = 268

    private let titleLabel = NSTextField(labelWithString: "Review")
    private let countLabel = NSTextField(labelWithString: "")
    private let nextLabel = NSTextField(labelWithString: "")

    /// The card: the prompt, where it came from, and the buttons.
    private let card = NSView()
    private let promptLabel = NSTextField(wrappingLabelWithString: "")
    private let sourceLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let revealButton = NSButton(title: "Show the note", target: nil, action: nil)
    private let againButton = NSButton(title: "Again", target: nil, action: nil)
    private let gotItButton = NSButton(title: "Got it", target: nil, action: nil)
    private let buttonRow = NSStackView()
    private let progress = NSProgressIndicator()

    private let emptyState = NSStackView()
    private let emptyIcon = NSImageView()
    private let emptyTitle = NSTextField(labelWithString: "")
    private let emptyHint = NSTextField(wrappingLabelWithString: "")

    /// The cards waiting to be answered.
    private var queue: [StudyNote] = []
    /// The card being shown.
    private var current: StudyNote?
    /// How many cards there were when the sitting began.
    private var totalCards = 0
    /// How many have been answered.
    private var reviewed = 0

    // MARK: - Build

    init() {
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        nextLabel.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = Typography.display()
        countLabel.font = Typography.secondary()
        countLabel.textColor = .secondaryLabelColor
        nextLabel.font = Typography.caption()
        nextLabel.textColor = .tertiaryLabelColor

        buildCard()
        buildEmptyState()

        addSubview(titleLabel)
        addSubview(countLabel)
        addSubview(nextLabel)
        addSubview(progress)
        addSubview(card)
        addSubview(emptyState)

        titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
        titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 18).isActive = true
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        // The label must not be stretched. A plain text field has a low
        // vertical hugging priority, so without a height of its own it takes
        // up whatever room is left over — which is how the heading ended up
        // 828 points tall and the count label ended up in the middle of the
        // window.
        titleLabel.heightAnchor.constraint(equalToConstant: 32).isActive = true

        countLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 12).isActive = true
        countLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor).isActive = true

        nextLabel.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
        nextLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4).isActive = true
        nextLabel.heightAnchor.constraint(equalToConstant: 15).isActive = true

        // The progress bar runs across the top of the desk, like a page
        // indicator: it says how far through the sitting you are.
        progress.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
        progress.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
        progress.topAnchor.constraint(equalTo: nextLabel.bottomAnchor, constant: 16).isActive = true
        progress.heightAnchor.constraint(equalToConstant: 4).isActive = true

        // The card is centred. It is a flashcard, not a page: it should be
        // the same size whatever the window is doing.
        card.centerXAnchor.constraint(equalTo: centerXAnchor).isActive = true
        card.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 26).isActive = true
        card.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -26).isActive = true
        card.widthAnchor.constraint(equalToConstant: Self.cardWidth).isActive = true
        card.heightAnchor.constraint(equalToConstant: Self.cardHeight).isActive = true

        emptyState.centerXAnchor.constraint(equalTo: centerXAnchor).isActive = true
        emptyState.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        emptyState.widthAnchor.constraint(lessThanOrEqualToConstant: 400).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildCard() {
        card.wantsLayer = true
        card.layer?.cornerRadius = 14
        card.layer?.backgroundColor = card.resolvedCGColor(NSColor.controlBackgroundColor)
        card.layer?.borderWidth = 1
        card.layer?.borderColor = card.resolvedCGColor(NSColor.separatorColor)
        card.translatesAutoresizingMaskIntoConstraints = false

        promptLabel.font = Typography.prompt()
        promptLabel.textColor = .labelColor
        promptLabel.translatesAutoresizingMaskIntoConstraints = false

        sourceLabel.font = Typography.caption(weight: .medium)
        sourceLabel.textColor = Palette.teal
        sourceLabel.translatesAutoresizingMaskIntoConstraints = false

        bodyLabel.font = Typography.body()
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.lineBreakMode = .byTruncatingTail
        // A long note cannot push the card off the screen.
        bodyLabel.maximumNumberOfLines = 6

        revealButton.bezelStyle = .rounded
        revealButton.controlSize = .regular
        revealButton.font = Typography.body(weight: .medium)
        revealButton.contentTintColor = Palette.accent
        revealButton.setColoredTitle("Show the note", color: Palette.accent,
                                     font: Typography.body(weight: .medium))
        revealButton.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
        revealButton.imagePosition = .imageLeading
        revealButton.imageHugsTitle = true
        revealButton.target = self
        revealButton.action = #selector(revealPressed)
        revealButton.translatesAutoresizingMaskIntoConstraints = false

        againButton.bezelStyle = .rounded
        againButton.controlSize = .regular
        againButton.font = Typography.body(weight: .medium)
        againButton.contentTintColor = Palette.rose
        againButton.setColoredTitle("Again", color: Palette.rose,
                                    font: Typography.body(weight: .medium))
        againButton.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: nil)
        againButton.imagePosition = .imageLeading
        againButton.imageHugsTitle = true
        againButton.target = self
        againButton.action = #selector(againPressed)
        againButton.translatesAutoresizingMaskIntoConstraints = false

        gotItButton.bezelStyle = .rounded
        gotItButton.controlSize = .regular
        gotItButton.font = Typography.body(weight: .medium)
        gotItButton.contentTintColor = Palette.green
        gotItButton.setColoredTitle("Got it", color: Palette.green,
                                    font: Typography.body(weight: .medium))
        gotItButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        gotItButton.imagePosition = .imageLeading
        gotItButton.imageHugsTitle = true
        gotItButton.target = self
        gotItButton.action = #selector(gotItPressed)
        gotItButton.translatesAutoresizingMaskIntoConstraints = false

        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        buttonRow.alignment = .centerY
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.addArrangedSubview(revealButton)
        buttonRow.addArrangedSubview(againButton)
        buttonRow.addArrangedSubview(gotItButton)

        // The progress bar has to be handed over to Auto Layout like
        // everything else. A view that keeps its autoresizing mask is never
        // moved by its constraints — it keeps the frame it was made with,
        // and everything anchored to it lands in the wrong place.
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(promptLabel)
        card.addSubview(sourceLabel)
        card.addSubview(bodyLabel)
        card.addSubview(buttonRow)

        // A wrapping label has to be given both edges, not a width: it needs
        // to know how wide it is before it can work out how tall it is.
        promptLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 28).isActive = true
        promptLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -28).isActive = true
        promptLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 26).isActive = true

        sourceLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 28).isActive = true
        sourceLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -28).isActive = true
        sourceLabel.topAnchor.constraint(equalTo: promptLabel.bottomAnchor, constant: 10).isActive = true

        bodyLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 28).isActive = true
        bodyLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -28).isActive = true
        bodyLabel.topAnchor.constraint(equalTo: sourceLabel.bottomAnchor, constant: 16).isActive = true

        buttonRow.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -28).isActive = true
        buttonRow.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -26).isActive = true
        buttonRow.leadingAnchor.constraint(greaterThanOrEqualTo: card.leadingAnchor, constant: 28).isActive = true

        // The answer never runs into the buttons.
        bodyLabel.bottomAnchor.constraint(lessThanOrEqualTo: buttonRow.topAnchor, constant: -18).isActive = true
    }

    private func buildEmptyState() {
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 8
        emptyState.translatesAutoresizingMaskIntoConstraints = false

        emptyIcon.image = NSImage(systemSymbolName: "brain.head.profile", accessibilityDescription: nil)
        emptyIcon.contentTintColor = Palette.gold
        emptyIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 38, weight: .light)
        emptyIcon.translatesAutoresizingMaskIntoConstraints = false

        emptyTitle.font = Typography.title()
        emptyTitle.textColor = .secondaryLabelColor

        emptyHint.font = Typography.body()
        emptyHint.textColor = .tertiaryLabelColor
        emptyHint.alignment = .center

        emptyState.addArrangedSubview(emptyIcon)
        emptyState.addArrangedSubview(emptyTitle)
        emptyState.addArrangedSubview(emptyHint)
    }

    // MARK: - Content

    /// Show the cards that are waiting.
    ///
    /// `upcoming` is how many notes are not due yet, which is worth saying —
    /// otherwise an empty desk looks like an empty brain.
    func show(due: [StudyNote], total: Int, upcoming: Int) {
        queue = due
        totalCards = due.count
        reviewed = 0
        current = due.first

        countLabel.stringValue = due.isEmpty
            ? (total == 0 ? "" : "Nothing due")
            : "\(due.count) of \(total) due"

        nextLabel.stringValue = upcoming > 0
            ? "\(upcoming) note\(upcoming == 1 ? "" : "s") waiting for another day"
            : ""

        card.isHidden = due.isEmpty
        emptyState.isHidden = !due.isEmpty
        progress.isHidden = due.isEmpty

        if due.isEmpty {
            if total == 0 {
                emptyIcon.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: nil)
                emptyTitle.stringValue = "Nothing to review yet"
                emptyHint.stringValue = "Write a note while you read, and it comes back here\nwhen it is time to remember it."
            } else {
                emptyIcon.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
                emptyTitle.stringValue = "All caught up"
                emptyHint.stringValue = "Every note has been reviewed.\nThey will come back when they are due."
            }
        }

        showCurrentCard()
    }

    /// Put the current card on screen.
    private func showCurrentCard() {
        guard let note = current else { return }

        let lines = note.body.split(separator: "\n", omittingEmptySubsequences: true)
        let first = lines.first.map(String.init) ?? note.preview

        promptLabel.stringValue = first.isEmpty ? "(an empty note)" : first
        sourceLabel.stringValue = note.documentTitle.isEmpty
            ? note.chapterLabel
            : "\(note.documentTitle) · \(note.chapterLabel)"

        // The rest of the note is the answer. It stays hidden until the
        // reader asks to see it — that is the whole point of the exercise.
        let rest = lines.dropFirst().joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        bodyLabel.stringValue = rest

        if rest.isEmpty {
            // A note of one line has nothing to hide, so it is rated
            // straight away rather than through a pointless reveal.
            bodyLabel.isHidden = true
            revealButton.isHidden = true
            againButton.isHidden = false
            gotItButton.isHidden = false
        } else {
            bodyLabel.isHidden = true
            revealButton.isHidden = false
            againButton.isHidden = true
            gotItButton.isHidden = true
        }

        progress.doubleValue = Double(reviewed) / Double(max(totalCards, 1))
    }

    // MARK: - Actions

    @objc private func revealPressed() {
        bodyLabel.isHidden = false
        revealButton.isHidden = true
        againButton.isHidden = false
        gotItButton.isHidden = false
    }

    @objc private func againPressed() {
        rate(remembered: false)
    }

    @objc private func gotItPressed() {
        rate(remembered: true)
    }

    private func rate(remembered: Bool) {
        guard let note = current else { return }
        onRate?(note.id, remembered)
        reviewed += 1

        if queue.isEmpty {
            current = nil
        } else {
            queue.removeFirst()
            current = queue.first
        }
        showCurrentCard()
    }

    // MARK: - Appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        card.layer?.backgroundColor = card.resolvedCGColor(NSColor.controlBackgroundColor)
        card.layer?.borderColor = card.resolvedCGColor(NSColor.separatorColor)
    }
}
