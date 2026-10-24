import Cocoa

/// A Spotlight-style command palette (⌘K).
///
/// The suite does a lot of things now — switch app, import, export, restart,
/// toggle web lookups, open the log — and burying them in a sidebar makes
/// them hard to find. The palette is one keystroke away.
final class CommandPalette {

    struct Command {
        let title: String
        let subtitle: String?
        let action: () -> Void

        init(title: String, subtitle: String? = nil, action: @escaping () -> Void) {
            self.title = title
            self.subtitle = subtitle
            self.action = action
        }
    }

    private static var panel: NSPanel?
    private static var field: PaletteField!
    private static var listStack: NSStackView!
    private static var commands: [Command] = []
    private static var matches: [Command] = []
    private static var highlighted = 0

    static func show(commands: [Command]) {
        self.commands = commands

        if panel == nil {
            buildPanel()
        }

        field.stringValue = ""
        matches = commands
        highlighted = 0
        rebuildList()

        panel?.orderFrontRegardless()
        panel?.makeKey()
        window?.makeFirstResponder(field)
    }

    static func hide() {
        panel?.orderOut(nil)
    }

    private static var window: NSWindow? { panel?.contentView?.window }

    // MARK: - Panel

    private static func buildPanel() {
        let content = NSView()
        content.wantsLayer = true
        content.layer?.cornerRadius = 12

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(effect)

        field = PaletteField()
        field.placeholderString = "Type a command…"
        field.font = .systemFont(ofSize: 17, weight: .medium)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.translatesAutoresizingMaskIntoConstraints = false
        field.onChange = { query in
            filter(query)
        }
        field.onSubmit = { runHighlighted() }
        field.onCancel = { hide() }
        field.onMove = { delta in
            moveHighlight(delta)
        }

        listStack = NSStackView()
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 0
        listStack.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(field)
        effect.addSubview(listStack)

        field.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16).isActive = true
        field.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16).isActive = true
        field.topAnchor.constraint(equalTo: effect.topAnchor, constant: 14).isActive = true
        field.heightAnchor.constraint(equalToConstant: 28).isActive = true

        listStack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 8).isActive = true
        listStack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -8).isActive = true
        listStack.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8).isActive = true
        listStack.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -10).isActive = true

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
                            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.contentView = content
        panel.center()

        self.panel = panel
    }

    // MARK: - List

    private static func filter(_ query: String) {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        if needle.isEmpty {
            matches = commands
        } else {
            matches = commands.filter { command in
                command.title.lowercased().contains(needle)
                    || (command.subtitle?.lowercased().contains(needle) ?? false)
            }
        }
        highlighted = 0
        rebuildList()
    }

    private static func rebuildList() {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        guard !matches.isEmpty else {
            let empty = NSTextField(labelWithString: "No matching command")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            listStack.addArrangedSubview(empty)
            return
        }

        for (index, command) in matches.enumerated() {
            let button = PaletteButton(command: command, highlighted: index == highlighted) {
                CommandPalette.run(command)
            }
            listStack.addArrangedSubview(button)
        }
    }

    private static func moveHighlight(_ delta: Int) {
        guard !matches.isEmpty else { return }
        highlighted = (highlighted + delta + matches.count) % matches.count
        rebuildList()
    }

    private static func runHighlighted() {
        guard matches.indices.contains(highlighted) else { return }
        run(matches[highlighted])
    }

    private static func run(_ command: Command) {
        hide()
        // Let the palette close before the command runs, otherwise a modal
        // sheet would appear behind it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            command.action()
        }
    }
}

// MARK: - Supporting views

/// The search field, with the palette's keyboard shortcuts wired in.
final class PaletteField: NSTextField {
    var onChange: ((String) -> Void)?
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onMove: ((Int) -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:      // escape
            onCancel?()
            return
        case 36, 76:  // return, enter
            onSubmit?()
            return
        case 125:     // down
            onMove?(1)
            return
        case 126:     // up
            onMove?(-1)
            return
        default:
            break
        }
        super.keyDown(with: event)
    }

    override func textDidChange(_ notification: Notification) {
        onChange?(stringValue)
    }
}

/// One row in the palette.
final class PaletteButton: NSButton {
    private let onPress: () -> Void

    init(command: CommandPalette.Command, highlighted: Bool, action: @escaping () -> Void) {
        self.onPress = action
        super.init(frame: .zero)

        title = command.title
        bezelStyle = .inline
        isBordered = false
        alignment = .left
        font = .systemFont(ofSize: 13, weight: highlighted ? .semibold : .regular)
        contentTintColor = highlighted ? .labelColor : .secondaryLabelColor
        target = self
        self.action = #selector(pressed)

        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 24).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 520).isActive = true

        if let subtitle = command.subtitle {
            toolTip = subtitle
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func pressed() {
        onPress()
    }
}
