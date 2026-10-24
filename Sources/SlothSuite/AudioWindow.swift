import Cocoa
import Foundation

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
        let content = NSView()
        // A real surface, so the headings and buttons have something to read
        // against.
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

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

        guard !briefing.chapters.isEmpty else {
            let empty = NSTextField(labelWithString: "This briefing has no chapters to read yet.")
            empty.font = Typography.body()
            empty.textColor = .secondaryLabelColor
            chapterStack.addArrangedSubview(empty)
            return
        }

        for (index, chapter) in briefing.chapters.enumerated() {
            // The card goes into the stack first: a constraint between the
            // card and the stack has no common ancestor until the card is
            // actually in it.
            let card = NSView()
            chapterStack.addArrangedSubview(card)
            configureCard(card, chapter: chapter, index: index)
        }
    }

    private func configureCard(_ card: NSView, chapter: BriefingChapter, index: Int) {
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false

        let number = NSTextField(labelWithString: "\(index + 1)")
        number.font = Typography.caption(weight: .bold)
        number.textColor = .secondaryLabelColor
        number.alignment = .center
        number.wantsLayer = true
        number.layer?.cornerRadius = 9
        number.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
        number.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: chapter.title)
        name.font = Typography.title()
        name.lineBreakMode = .byTruncatingTail

        let pages = NSTextField(labelWithString: chapter.pageRange)
        pages.font = Typography.caption()
        pages.textColor = .tertiaryLabelColor

        let playButton = NSButton(title: "Play", target: self, action: #selector(playChapter(_:)))
        playButton.bezelStyle = .rounded
        playButton.controlSize = .regular
        playButton.font = Typography.body(weight: .medium)
        playButton.image = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: nil)
        playButton.imagePosition = .imageLeading
        playButton.imageHugsTitle = true
        playButton.tag = index
        playButton.setContentHuggingPriority(.required, for: .horizontal)

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

        let titleRow = NSStackView(views: [number, name, pages, playButton])
        titleRow.orientation = .horizontal
        titleRow.spacing = 10
        titleRow.alignment = .centerY
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        titleRow.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        card.addSubview(titleRow)
        card.addSubview(script)

        titleRow.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16).isActive = true
        titleRow.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16).isActive = true
        titleRow.topAnchor.constraint(equalTo: card.topAnchor, constant: 14).isActive = true
        number.widthAnchor.constraint(equalToConstant: 20).isActive = true
        number.heightAnchor.constraint(equalToConstant: 20).isActive = true

        script.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16).isActive = true
        script.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16).isActive = true
        script.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 10).isActive = true
        script.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16).isActive = true

        // The card is as wide as the page, so the script has a proper measure
        // to wrap in instead of being squeezed to nothing.
        card.widthAnchor.constraint(equalTo: chapterStack.widthAnchor).isActive = true
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
