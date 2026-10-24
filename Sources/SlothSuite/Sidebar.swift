import Cocoa

/// One app row in the sidebar: status dot, title, tagline and health text.
final class AppRow: NSStackView {
    let spec: AppSpec

    private let dot: NSView
    private let button: NSButton
    private let tagline: NSTextField
    private let status: NSTextField

    init(spec: AppSpec, onSelect: @escaping () -> Void) {
        self.spec = spec
        self.dot = NSView()
        self.button = NSButton(title: spec.title, target: nil, action: nil)
        self.tagline = NSTextField(labelWithString: spec.tagline)
        self.status = NSTextField(labelWithString: "…")

        super.init(frame: .zero)

        orientation = .vertical
        alignment = .leading
        spacing = 1
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = NSColor.systemGray.cgColor
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true

        button.bezelStyle = .inline
        button.isBordered = false
        button.font = .systemFont(ofSize: 13, weight: .semibold)
        button.target = self
        button.action = #selector(pressed)

        // The closure approach avoids relying on a button title to identify
        // which app a row belongs to.
        onClick = onSelect

        titleRow.addArrangedSubview(dot)
        titleRow.addArrangedSubview(button)

        tagline.font = .systemFont(ofSize: 10)
        tagline.textColor = .tertiaryLabelColor
        tagline.lineBreakMode = .byTruncatingTail

        status.font = .systemFont(ofSize: 10)
        status.textColor = .tertiaryLabelColor

        addArrangedSubview(titleRow)
        addArrangedSubview(tagline)
        addArrangedSubview(status)

        titleRow.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
        titleRow.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor).isActive = true
        tagline.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
        tagline.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor).isActive = true
        status.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
        status.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor).isActive = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var onClick: (() -> Void)?

    @objc private func pressed() {
        onClick?()
    }

    func update(statusText: String, healthy: Bool, selected: Bool) {
        status.stringValue = statusText

        // The healthy dot takes the app's own colour; a failure is always
        // red. Previously every healthy dot was the same green, so the two
        // apps were indistinguishable in the sidebar.
        dot.layer?.backgroundColor = (healthy ? spec.dotColor : NSColor.systemRed).cgColor

        button.font = .systemFont(ofSize: 13, weight: selected ? .bold : .semibold)
        button.contentTintColor = selected ? .labelColor : .secondaryLabelColor

        layer?.backgroundColor = selected
            ? NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
            : NSColor.clear.cgColor
        layer?.cornerRadius = 6
    }
}

/// The suite's sidebar: the app list, the library, the actions and the
/// live status read-outs.
final class SidebarView: NSVisualEffectView {
    var onSelect: ((String) -> Void)?
    var onAction: ((SidebarAction) -> Void)?

    enum SidebarAction {
        case addBook
        case exportBriefing
        case restartStack
        case reloadPage
        case showLogs
        case toggleWeb
        case openDocument(String)
    }

    private(set) var rows: [String: AppRow] = [:]
    private let stackLabel = NSTextField(labelWithString: "Stack: checking…")
    private let aiLabel = NSTextField(labelWithString: "Local AI: checking…")
    private let webLabel = NSTextField(labelWithString: "Web: checking…")
    private let webButton = NSButton(title: "Enable web lookups", target: nil, action: nil)
    private let libraryPanel = LibraryPanel()

    private var selectedId: String?
    private var statuses: [String: HealthMonitor.Status] = [:]

    init(specs: [AppSpec]) {
        super.init(frame: .zero)

        material = .sidebar
        blendingMode = .behindWindow
        translatesAutoresizingMaskIntoConstraints = false

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 4
        root.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "Sloth Suite")
        titleLabel.font = .systemFont(ofSize: 16, weight: .bold)

        // The old tagline claimed "Local · private · offline". That is no
        // longer true — the apps can look things up on the web — so the
        // sidebar says what actually happens.
        let subtitleLabel = NSTextField(labelWithString: "Local AI · web lookups optional")
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor

        root.addArrangedSubview(titleLabel)
        root.addArrangedSubview(subtitleLabel)
        root.addArrangedSubview(Self.gap(14))

        let appStack = NSStackView()
        appStack.orientation = .vertical
        appStack.alignment = .leading
        appStack.spacing = 6
        appStack.translatesAutoresizingMaskIntoConstraints = false

        for spec in specs {
            let row = AppRow(spec: spec, onSelect: { [weak self] in
                self?.onSelect?(spec.id)
            })
            rows[spec.id] = row
            appStack.addArrangedSubview(row)
        }

        root.addArrangedSubview(appStack)
        root.addArrangedSubview(Self.gap(12))

        if specs.contains(where: { $0.supportsLibrary }) {
            let heading = NSTextField(labelWithString: "Library")
            heading.font = .systemFont(ofSize: 11, weight: .semibold)
            heading.textColor = .secondaryLabelColor
            root.addArrangedSubview(heading)
            root.addArrangedSubview(libraryPanel)
            root.addArrangedSubview(Self.gap(12))
        }

        root.addArrangedSubview(makeButton("Add a book…", action: .addBook))
        root.addArrangedSubview(makeButton("Export briefing…", action: .exportBriefing))
        root.addArrangedSubview(Self.gap(10))
        root.addArrangedSubview(makeButton("Restart stack", action: .restartStack))
        root.addArrangedSubview(makeButton("Reload page", action: .reloadPage))
        root.addArrangedSubview(makeButton("Show logs", action: .showLogs))
        root.addArrangedSubview(Self.gap(8))

        webButton.bezelStyle = .rounded
        webButton.controlSize = .small
        webButton.target = self
        webButton.action = #selector(webToggled)
        root.addArrangedSubview(webButton)

        root.addArrangedSubview(Self.gap(12))

        for label in [stackLabel, aiLabel, webLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            root.addArrangedSubview(label)
        }

        root.addArrangedSubview(Self.gap(10))
        let footer = NSTextField(wrappingLabelWithString:
            "Documents stay on this machine. Web lookups only send the search terms the model asks for.")
        footer.font = .systemFont(ofSize: 10)
        footer.textColor = .tertiaryLabelColor
        footer.lineBreakMode = .byWordWrapping
        root.addArrangedSubview(footer)

        addSubview(root)
        root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16).isActive = true
        root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12).isActive = true
        root.topAnchor.constraint(equalTo: topAnchor, constant: 18).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Building blocks

    private func makeButton(_ title: String, action: SidebarAction) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(actionPressed(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.tag = SidebarActionTag.rawValue(for: action)
        return button
    }

    private static func gap(_ height: CGFloat) -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: height).isActive = true
        return spacer
    }

    // MARK: - Actions

    @objc private func actionPressed(_ sender: NSButton) {
        guard let action = SidebarActionTag.action(for: sender.tag) else { return }
        onAction?(action)
    }

    @objc private func webToggled() {
        onAction?(.toggleWeb)
    }

    // MARK: - State

    func setSelected(id: String) {
        selectedId = id
        refreshRows()
    }

    func update(status: HealthMonitor.Status, for id: String) {
        statuses[id] = status
        refreshRows()
    }

    private func refreshRows() {
        for (id, row) in rows {
            let status = statuses[id] ?? .unknown
            row.update(statusText: status.detail,
                      healthy: status.ok,
                      selected: id == selectedId)
        }
    }

    func setStack(_ text: String) { stackLabel.stringValue = text }
    func setAI(_ text: String) { aiLabel.stringValue = text }

    func setWeb(_ enabled: Bool?) {
        guard let enabled else {
            webLabel.stringValue = "Web: checking…"
            return
        }
        webLabel.stringValue = enabled ? "Web: on" : "Web: off"
        webButton.title = enabled ? "Disable web lookups" : "Enable web lookups"
    }

    func library() -> LibraryPanel { libraryPanel }
}

/// Maps sidebar buttons to actions without a stringly-typed mess.
enum SidebarActionTag {
    static func rawValue(for action: SidebarView.SidebarAction) -> Int {
        switch action {
        case .addBook: return 1
        case .exportBriefing: return 2
        case .restartStack: return 3
        case .reloadPage: return 4
        case .showLogs: return 5
        case .toggleWeb: return 6
        case .openDocument: return 7
        }
    }

    static func action(for tag: Int) -> SidebarView.SidebarAction? {
        switch tag {
        case 1: return .addBook
        case 2: return .exportBriefing
        case 3: return .restartStack
        case 4: return .reloadPage
        case 5: return .showLogs
        case 6: return .toggleWeb
        default: return nil
        }
    }
}
