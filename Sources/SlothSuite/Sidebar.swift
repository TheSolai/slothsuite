import Cocoa

/// The suite's sidebar: functional navigation, nothing else.
///
/// The old sidebar was a wall of small grey buttons, a block of status text
/// and a paragraph of boilerplate. Everything that belonged in a menu went
/// into a menu, and the sidebar became what it should be — a way to move
/// between the parts of the suite.
final class SidebarView: NSVisualEffectView {

    var onSelectModule: ((String) -> Void)?
    var onAction: ((SidebarAction) -> Void)?

    enum SidebarAction {
        case addDocument
        case newNote
        case continueReading
        case exportFiles
        case speak
        case allAudio
        case audioChapters
        case restartStack
        case reloadPage
        case showLogs
        case copyDiagnostics
        case toggleWeb
        case setProvider(String)
        case openDocument(String)
        case deleteDocument(String, String)
    }

    private var navButtons: [String: NavButton] = [:]
    private let statusLabel = NSTextField(labelWithString: "")
    private let providerLabel = NSTextField(labelWithString: "")
    private let menuButton = NSButton(title: "", target: nil, action: nil)

    init(modules: [SuiteModule]) {

        // Auto Layout positions these, so the autoresizing mask must not
        // fight it — a view with the mask on keeps its old frame and is
        // never moved by its constraints.
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        providerLabel.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: .zero)

        material = .sidebar
        blendingMode = .behindWindow
        translatesAutoresizingMaskIntoConstraints = false

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 2
        root.translatesAutoresizingMaskIntoConstraints = false

        let wordmark = NSTextField(labelWithString: "Sloth Suite")
        wordmark.font = Typography.wordmark()

        let tagline = NSTextField(labelWithString: "Your learning desk")
        tagline.font = Typography.secondary()
        tagline.textColor = .secondaryLabelColor

        root.addArrangedSubview(wordmark)
        root.addArrangedSubview(tagline)
        root.addArrangedSubview(Self.gap(16))

        for module in modules {
            let button = NavButton(module: module)
            button.onPress = { [weak self] in
                guard let self, module.isAvailable else { return }
                self.onSelectModule?(module.id)
            }
            navButtons[module.id] = button
            root.addArrangedSubview(button)
        }

        root.addArrangedSubview(Self.gap(14))

        // A single, quiet line instead of a wall of status text.
        let statusBox = NSView()
        statusBox.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = Typography.secondary()
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        providerLabel.font = Typography.caption()
        providerLabel.textColor = .tertiaryLabelColor
        providerLabel.lineBreakMode = .byTruncatingTail

        statusBox.addSubview(statusLabel)
        statusBox.addSubview(providerLabel)
        statusLabel.leadingAnchor.constraint(equalTo: statusBox.leadingAnchor).isActive = true
        statusLabel.trailingAnchor.constraint(equalTo: statusBox.trailingAnchor).isActive = true
        statusLabel.topAnchor.constraint(equalTo: statusBox.topAnchor).isActive = true
        providerLabel.leadingAnchor.constraint(equalTo: statusBox.leadingAnchor).isActive = true
        providerLabel.trailingAnchor.constraint(equalTo: statusBox.trailingAnchor).isActive = true
        providerLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 2).isActive = true
        statusBox.bottomAnchor.constraint(equalTo: providerLabel.bottomAnchor).isActive = true

        // A fixed width so the labels truncate instead of pushing the sidebar
        // wider than its own column.
        statusBox.widthAnchor.constraint(equalToConstant: 194).isActive = true

        root.addArrangedSubview(statusBox)

        // Everything that is not navigation lives behind one menu.
        menuButton.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More")
        menuButton.bezelStyle = .inline
        menuButton.isBordered = false
        menuButton.contentTintColor = .secondaryLabelColor
        menuButton.target = self
        menuButton.action = #selector(showMenu)
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        menuButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        menuButton.heightAnchor.constraint(equalToConstant: 24).isActive = true

        root.addArrangedSubview(Self.gap(4))
        root.addArrangedSubview(menuButton)

        addSubview(root)
        root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14).isActive = true
        root.trailingAnchor.constraint(equalTo: leadingAnchor, constant: 214).isActive = true
        root.topAnchor.constraint(equalTo: topAnchor, constant: 18).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - State

    func setSelectedModule(id: String) {
        for (moduleId, button) in navButtons {
            button.isChosen = (moduleId == id)
        }
    }

    /// One quiet line: what is running.
    func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    func setProvider(_ text: String) {
        providerLabel.stringValue = text
    }

    // MARK: - Menu

    @objc private func showMenu() {
        let menu = NSMenu()

        menu.addItem(item("Add Document", .addDocument))
        menu.addItem(item("New Note", .newNote))
        menu.addItem(item("Continue Reading", .continueReading))
        menu.addItem(.separator())
        menu.addItem(item("Export as Separate Files…", .exportFiles))
        menu.addItem(.separator())
        menu.addItem(item("Read Everything Aloud", .allAudio))
        menu.addItem(item("Audio and Chapters…", .audioChapters))
        menu.addItem(.separator())
        menu.addItem(item("Reload Page", .reloadPage))
        menu.addItem(item("Restart Stack", .restartStack))
        menu.addItem(.separator())
        menu.addItem(item("Show Logs", .showLogs))
        menu.addItem(item("Copy Diagnostics", .copyDiagnostics))

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: menuButton.bounds.height + 6), in: menuButton)
    }

    private func item(_ title: String, _ action: SidebarAction) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: #selector(handleMenuItem(_:)), keyEquivalent: "")
        menuItem.target = self
        menuItem.representedObject = action
        return menuItem
    }

    @objc func handleMenuItem(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? SidebarAction else { return }
        onAction?(action)
    }

    private static func gap(_ height: CGFloat) -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: height).isActive = true
        return spacer
    }
}

// MARK: - Navigation button

/// A sidebar row: an icon and a label, with a selection highlight.
final class NavButton: NSButton {
    var onPress: (() -> Void)?
    private let module: SuiteModule

    var isChosen: Bool = false {
        didSet { updateAppearance() }
    }

    private var isHovering = false {
        didSet { updateAppearance() }
    }

    init(module: SuiteModule) {
        self.module = module
        super.init(frame: .zero)

        title = module.title
        image = NSImage(systemSymbolName: module.symbol, accessibilityDescription: nil)
        imagePosition = .imageLeading
        imageHugsTitle = true
        bezelStyle = .inline
        isBordered = false
        alignment = .left
        font = Typography.body(weight: .medium)
        contentTintColor = .secondaryLabelColor
        target = self
        action = #selector(pressed)

        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 32).isActive = true
        widthAnchor.constraint(equalToConstant: 194).isActive = true

        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true

        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))

        updateAppearance()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
        guard module.isAvailable else {
            contentTintColor = .tertiaryLabelColor
            font = Typography.body(weight: .regular)
            alphaValue = 0.5
            layer?.backgroundColor = NSColor.clear.cgColor
            return
        }

        alphaValue = 1

        if isChosen {
            // A filled pill, the way macOS marks the current source list row.
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.20).cgColor
            contentTintColor = .labelColor
            font = Typography.body(weight: .semibold)
        } else if isHovering {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
            contentTintColor = .labelColor
            font = Typography.body(weight: .medium)
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            contentTintColor = .secondaryLabelColor
            font = Typography.body(weight: .medium)
        }
    }

    @objc private func pressed() {
        onPress?()
    }
}
