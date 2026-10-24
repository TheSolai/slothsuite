import Cocoa

// MARK: - Card grid layout

/// A grid that divides the available width into equal columns.
///
/// `NSCollectionViewFlowLayout` justifies each row to fill the width, so the
/// cards come out wider than they were specified and the last card in a row
/// is stretched. It also warns when a fixed item size is wider than the
/// collection view. This layout computes exact frames instead, so the cards
/// stay the size they were designed to be at every window width.
final class LibraryGridLayout: NSCollectionViewFlowLayout {
    var itemHeight: CGFloat = 124

    /// The width a card would like to be.
    private let targetWidth: CGFloat = 284

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != collectionView?.bounds.width
    }

    override func prepare() {
        super.prepare()
        // Nothing to cache — frames are computed on demand.
    }

    /// How many columns fit at the preferred card width.
    private func columnCount(for available: CGFloat) -> Int {
        let spacing = minimumInteritemSpacing
        guard available > 0 else { return 1 }
        return max(1, Int((available + spacing) / (targetWidth + spacing)))
    }

    private func columnWidth(for available: CGFloat) -> CGFloat {
        let spacing = minimumInteritemSpacing
        let columns = columnCount(for: available)
        return floor((available - spacing * CGFloat(columns - 1)) / CGFloat(columns))
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        guard let collectionView else { return [] }

        let available = collectionView.bounds.width - sectionInset.left - sectionInset.right
        guard available > 0 else { return [] }

        let spacing = minimumInteritemSpacing
        let columns = columnCount(for: available)
        let width = columnWidth(for: available)
        let count = collectionView.numberOfItems(inSection: 0)

        var result: [NSCollectionViewLayoutAttributes] = []
        for item in 0..<count {
            let indexPath = IndexPath(item: item, section: 0)
            let row = item / columns
            let column = item % columns

            let frame = NSRect(
                x: sectionInset.left + CGFloat(column) * (width + spacing),
                y: sectionInset.top + CGFloat(row) * (itemHeight + minimumLineSpacing),
                width: width,
                height: itemHeight
            )

            // A generous margin so partially scrolled rows are never missing.
            let visible = rect.insetBy(dx: -400, dy: -400)
            guard frame.intersects(visible) else { continue }

            let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
            attributes.frame = frame
            result.append(attributes)
        }
        return result
    }

    override var collectionViewContentSize: NSSize {
        guard let collectionView else { return .zero }

        let available = collectionView.bounds.width - sectionInset.left - sectionInset.right
        guard available > 0 else { return .zero }

        let count = collectionView.numberOfItems(inSection: 0)
        guard count > 0 else { return .zero }

        let columns = columnCount(for: available)
        let rows = Int(ceil(Double(count) / Double(columns)))
        let height = CGFloat(rows) * itemHeight + CGFloat(max(0, rows - 1)) * minimumLineSpacing

        return NSSize(width: collectionView.bounds.width,
                      height: height + sectionInset.top + sectionInset.bottom)
    }
}

// MARK: - The library

/// The native library: a card grid of everything SlothRead has ingested.
///
/// This is the suite's front door. The old layout put a cramped list of
/// document names in the sidebar, which made the library feel like a side
/// note rather than the main event.
final class LibraryView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate {

    var onOpen: ((LibraryDocument) -> Void)?
    var onExport: ((LibraryDocument) -> Void)?
    var onSpeak: ((LibraryDocument) -> Void)?
    var onDelete: ((LibraryDocument) -> Void)?
    var onAdd: (() -> Void)?
    var onToggleFavourite: ((LibraryDocument) -> Void)?
    var onToggleRead: ((LibraryDocument) -> Void)?
    var onAddNote: ((LibraryDocument) -> Void)?
    var onFilterChange: ((LibraryFilter) -> Void)?
    var onContinue: (() -> Void)?

    private let collectionView = NSCollectionView()
    private let titleLabel = NSTextField(labelWithString: "Library")
    private let countLabel = NSTextField(labelWithString: "")
    private let searchField = NSSearchField()
    private let emptyState = NSStackView()
    private let emptyTitle = NSTextField(labelWithString: "Your library is empty")
    private let emptyHint = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let filterBar = NSStackView()
    private let header = NSView()
    private let filterRow = NSView()
    private let continueButton = NSButton(title: "Continue reading", target: nil, action: nil)
    private var filterButtons: [LibraryFilter: FilterChip] = [:]

    private var documents: [LibraryDocument] = []
    private var addButton: NSButton!

    /// A dump of the header's frames, for diagnosing a bad layout.
    func headerFrames() -> String {
        "self \(frame) header \(header.frame) title \(titleLabel.frame) count \(countLabel.frame) search \(searchField.frame) add \(addButton.frame) filter \(filterRow.frame)"
    }

    // MARK: - Build

    init() {

        // Auto Layout positions these, so the autoresizing mask must not
        // fight it — a view with the mask on keeps its old frame and is
        // never moved by its constraints.
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // Header
        header.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = Typography.display()

        countLabel.font = Typography.secondary()
        countLabel.textColor = .secondaryLabelColor

        searchField.placeholderString = "Search documents"
        searchField.font = Typography.body()
        searchField.controlSize = .regular
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.sendsSearchStringImmediately = false
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        searchField.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
        // The search field is the first thing to give up room. The count and
        // the title keep their space, so the header never draws on top of
        // itself the way a fixed-width field did.
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let addButton = NSButton(title: "Add Document", target: self, action: #selector(addPressed))
        self.addButton = addButton
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.bezelStyle = .rounded
        addButton.controlSize = .regular
        addButton.font = Typography.body(weight: .medium)
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add document")
        addButton.imagePosition = .imageLeading
        // The one action on this screen wears the suite's colour.
        addButton.contentTintColor = Palette.accent
        addButton.setColoredTitle("Add Document", color: Palette.accent,
                                  font: Typography.body(weight: .medium))

        header.addSubview(titleLabel)
        header.addSubview(countLabel)
        header.addSubview(searchField)
        header.addSubview(addButton)

        titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor).isActive = true
        titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor).isActive = true
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        countLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 12).isActive = true
        countLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor).isActive = true
        countLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addButton.trailingAnchor.constraint(equalTo: header.trailingAnchor).isActive = true
        addButton.centerYAnchor.constraint(equalTo: header.centerYAnchor).isActive = true
        addButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        searchField.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -14).isActive = true
        searchField.centerYAnchor.constraint(equalTo: header.centerYAnchor).isActive = true
        searchField.leadingAnchor.constraint(greaterThanOrEqualTo: countLabel.trailingAnchor, constant: 16).isActive = true

        header.heightAnchor.constraint(equalToConstant: 38).isActive = true

        // Filter chips.
        //
        // The library is going to grow, so the way you slice it matters more
        // than the raw count. All / Favourites / Unread / Ready, each showing
        // how many documents it holds.
        filterBar.orientation = .horizontal
        filterBar.alignment = .centerY
        filterBar.spacing = 6
        filterBar.translatesAutoresizingMaskIntoConstraints = false

        for candidate in LibraryFilter.allCases {
            let button = FilterChip(filter: candidate)
            button.onPress = { [weak self] in
                self?.onFilterChange?(candidate)
            }
            filterButtons[candidate] = button
            filterBar.addArrangedSubview(button)
        }

        // Continue reading — the single most useful shortcut in a library
        // that is growing.
        continueButton.title = "Continue reading"
        continueButton.font = Typography.body(weight: .medium)
        continueButton.bezelStyle = .inline
        continueButton.isBordered = false
        continueButton.contentTintColor = Palette.blue
        continueButton.setColoredTitle("Continue reading", color: Palette.blue,
                                       font: Typography.body(weight: .medium))
        continueButton.image = NSImage(systemSymbolName: "arrow.right.circle", accessibilityDescription: nil)
        continueButton.imagePosition = .imageLeading
        continueButton.imageHugsTitle = true
        continueButton.target = self
        continueButton.action = #selector(continuePressed)
        continueButton.translatesAutoresizingMaskIntoConstraints = false
        continueButton.isHidden = true

        // The chips sit on the left, the continue button on the right, in a
        // plain container rather than a stack view, so neither has to guess
        // how to share the row.
        filterRow.translatesAutoresizingMaskIntoConstraints = false
        filterRow.addSubview(filterBar)
        filterRow.addSubview(continueButton)

        filterBar.leadingAnchor.constraint(equalTo: filterRow.leadingAnchor).isActive = true
        filterBar.topAnchor.constraint(equalTo: filterRow.topAnchor).isActive = true
        filterBar.bottomAnchor.constraint(equalTo: filterRow.bottomAnchor).isActive = true

        continueButton.trailingAnchor.constraint(equalTo: filterRow.trailingAnchor).isActive = true
        continueButton.centerYAnchor.constraint(equalTo: filterRow.centerYAnchor).isActive = true
        continueButton.leadingAnchor.constraint(greaterThanOrEqualTo: filterBar.trailingAnchor, constant: 12).isActive = true

        // Collection view
        let layout = LibraryGridLayout()
        layout.itemSize = NSSize(width: 284, height: 138)
        layout.itemHeight = 138
        layout.minimumInteritemSpacing = 14
        layout.minimumLineSpacing = 14
        layout.sectionInset = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(LibraryCardItem.self, forItemWithIdentifier: LibraryCardItem.identifier)
        collectionView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Empty state
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 6
        emptyState.translatesAutoresizingMaskIntoConstraints = false

        let emptyIcon = NSImageView()
        emptyIcon.image = NSImage(systemSymbolName: "books.vertical", accessibilityDescription: nil)
        emptyIcon.contentTintColor = .tertiaryLabelColor
        emptyIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 34, weight: .light)
        emptyIcon.translatesAutoresizingMaskIntoConstraints = false

        emptyTitle.font = Typography.title()
        emptyTitle.textColor = .secondaryLabelColor

        emptyHint.font = Typography.body()
        emptyHint.textColor = .tertiaryLabelColor
        emptyHint.alignment = .center
        emptyHint.stringValue = "Drop a PDF or an EPUB anywhere in this window,\nor press Add Document."

        emptyState.addArrangedSubview(emptyIcon)
        emptyState.addArrangedSubview(emptyTitle)
        emptyState.addArrangedSubview(emptyHint)

        addSubview(header)
        addSubview(filterRow)
        addSubview(scrollView)
        addSubview(emptyState)

        header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24).isActive = true
        header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24).isActive = true
        header.topAnchor.constraint(equalTo: topAnchor, constant: 18).isActive = true

        filterRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24).isActive = true
        filterRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24).isActive = true
        filterRow.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10).isActive = true
        filterRow.heightAnchor.constraint(equalToConstant: 26).isActive = true

        scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24).isActive = true
        scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24).isActive = true
        scrollView.topAnchor.constraint(equalTo: filterRow.bottomAnchor, constant: 12).isActive = true
        scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20).isActive = true

        emptyState.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor).isActive = true
        emptyState.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Content

    func update(documents: [LibraryDocument]) {
        self.documents = documents

        let total = LibraryStore.shared.documents.count
        countLabel.stringValue = documents.isEmpty
            ? ""
            : "\(documents.count) of \(total) document\(total == 1 ? "" : "s")"

        // An empty result can mean "no documents at all" or "this filter has
        // nothing" — the two need different words.
        if total == 0 {
            emptyTitle.stringValue = "Your library is empty"
            emptyHint.stringValue = "Drop a PDF or an EPUB anywhere in this window,\nor press Add Document."
        } else {
            emptyTitle.stringValue = "Nothing here"
            emptyHint.stringValue = "No documents match this view.\nTry another filter, or clear the search."
        }

        let isEmpty = documents.isEmpty
        emptyState.isHidden = !isEmpty
        scrollView.isHidden = isEmpty
        collectionView.reloadData()

        refreshFilterChips()
    }

    /// Keep the chip counts and the selected chip in step with the store.
    private func refreshFilterChips() {
        let store = LibraryStore.shared
        for (candidate, button) in filterButtons {
            button.setCount(store.count(for: candidate))
            button.isChosen = (store.filter == candidate)
        }
    }

    /// Show or hide the "Continue reading" shortcut.
    func setContinue(title: String?) {
        if let title {
            // The coloured title has to be set here too: assigning `title`
            // throws away an attributed title, and the button would go grey.
            continueButton.setColoredTitle("Continue “\(title)”", color: Palette.blue,
                                           font: Typography.body(weight: .medium))
            continueButton.isHidden = false
        } else {
            continueButton.isHidden = true
        }
    }

    @objc private func continuePressed() {
        onContinue?()
    }

    /// Put the cursor in the search field, so ⌘L lands the user where they
    /// want to type.
    func focusSearch() {
        window?.makeFirstResponder(searchField)
    }

    @objc private func searchChanged() {
        LibraryStore.shared.setQuery(searchField.stringValue)
    }

    @objc private func addPressed() {
        onAdd?()
    }

    // MARK: - Collection view

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        documents.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: LibraryCardItem.identifier, for: indexPath)
        if let card = item as? LibraryCardItem {
            card.configure(with: documents[indexPath.item])
            card.onOpen = { [weak self] in
                guard let self, indexPath.item < self.documents.count else { return }
                self.onOpen?(self.documents[indexPath.item])
            }
            card.onMenu = { [weak self] menu in
                guard let self, indexPath.item < self.documents.count else { return }
                let document = self.documents[indexPath.item]
                let menu = NSMenu()
                let open = NSMenuItem(title: "Open", action: #selector(handleCardMenu(_:)), keyEquivalent: "")
                open.target = self
                open.representedObject = document.id
                open.tag = LibraryCardMenuTag.open
                menu.addItem(open)

                let export = NSMenuItem(title: "Export as separate files…", action: #selector(handleCardMenu(_:)), keyEquivalent: "")
                export.target = self
                export.representedObject = document.id
                export.tag = LibraryCardMenuTag.export
                menu.addItem(export)

                let speak = NSMenuItem(title: "Speak the summary…", action: #selector(handleCardMenu(_:)), keyEquivalent: "")
                speak.target = self
                speak.representedObject = document.id
                speak.tag = LibraryCardMenuTag.speak
                menu.addItem(speak)

                let note = NSMenuItem(title: "Add a note…", action: #selector(handleCardMenu(_:)), keyEquivalent: "")
                note.target = self
                note.representedObject = document.id
                note.tag = LibraryCardMenuTag.note
                menu.addItem(note)

                menu.addItem(.separator())

                let favourite = NSMenuItem(title: "Favourite", action: #selector(handleCardMenu(_:)), keyEquivalent: "")
                favourite.target = self
                favourite.representedObject = document.id
                favourite.tag = LibraryCardMenuTag.favourite
                menu.addItem(favourite)

                let read = NSMenuItem(title: "Mark as read", action: #selector(handleCardMenu(_:)), keyEquivalent: "")
                read.target = self
                read.representedObject = document.id
                read.tag = LibraryCardMenuTag.read
                menu.addItem(read)

                menu.addItem(.separator())

                let delete = NSMenuItem(title: "Remove from library", action: #selector(handleCardMenu(_:)), keyEquivalent: "")
                delete.target = self
                delete.representedObject = document.id
                delete.tag = LibraryCardMenuTag.delete
                menu.addItem(delete)
            }
            card.onToggleFavourite = { [weak self] in
                guard let self, indexPath.item < self.documents.count else { return }
                self.onToggleFavourite?(self.documents[indexPath.item])
            }
            card.onToggleRead = { [weak self] in
                guard let self, indexPath.item < self.documents.count else { return }
                self.onToggleRead?(self.documents[indexPath.item])
            }
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let indexPath = indexPaths.first, indexPath.item < documents.count else { return }
        onOpen?(documents[indexPath.item])
    }

    // MARK: - Card menu

    @objc func handleCardMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let document = LibraryStore.shared.document(id: id) else { return }
        switch sender.tag {
        case LibraryCardMenuTag.open: onOpen?(document)
        case LibraryCardMenuTag.export: onExport?(document)
        case LibraryCardMenuTag.speak: onSpeak?(document)
        case LibraryCardMenuTag.delete: onDelete?(document)
        case LibraryCardMenuTag.note: onAddNote?(document)
        case LibraryCardMenuTag.favourite: onToggleFavourite?(document)
        case LibraryCardMenuTag.read: onToggleRead?(document)
        default: break
        }
    }
}

enum LibraryCardMenuTag {
    static let open = 1
    static let export = 2
    static let speak = 3
    static let delete = 4
    static let note = 5
    static let favourite = 6
    static let read = 7
}

// MARK: - The card

/// One document card.
final class LibraryCardItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("LibraryCardItem")

    var onOpen: (() -> Void)?
    var onMenu: ((NSMenu) -> Void)?

    private let card = NSView()
    private let typeBadge = NSTextField(labelWithString: "PDF")
    private let dateLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let authorLabel = NSTextField(labelWithString: "")
    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let menuButton = NSButton(title: "", target: nil, action: nil)
    private let starButton = NSButton(title: "", target: nil, action: nil)
    private let readButton = NSButton(title: "", target: nil, action: nil)

    var onToggleFavourite: (() -> Void)?
    var onToggleRead: (() -> Void)?

    override func loadView() {
        let container = NSView()

        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false

        typeBadge.font = Typography.caption(weight: .bold)
        typeBadge.textColor = .secondaryLabelColor
        typeBadge.alignment = .center
        typeBadge.wantsLayer = true
        typeBadge.layer?.cornerRadius = 4
        typeBadge.translatesAutoresizingMaskIntoConstraints = false

        dateLabel.font = Typography.caption()
        dateLabel.textColor = .tertiaryLabelColor
        dateLabel.alignment = .right
        dateLabel.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = Typography.title()
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 2
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        authorLabel.font = Typography.secondary()
        authorLabel.textColor = .secondaryLabelColor
        authorLabel.lineBreakMode = .byTruncatingTail
        authorLabel.translatesAutoresizingMaskIntoConstraints = false

        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3
        statusDot.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = Typography.caption()
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        menuButton.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More")
        menuButton.bezelStyle = .inline
        menuButton.isBordered = false
        menuButton.contentTintColor = .tertiaryLabelColor
        menuButton.target = self
        menuButton.action = #selector(menuPressed)
        menuButton.translatesAutoresizingMaskIntoConstraints = false

        starButton.image = NSImage(systemSymbolName: "star", accessibilityDescription: "Favourite")
        starButton.bezelStyle = .inline
        starButton.isBordered = false
        starButton.contentTintColor = .tertiaryLabelColor
        starButton.target = self
        starButton.action = #selector(starPressed)
        starButton.translatesAutoresizingMaskIntoConstraints = false
        starButton.toolTip = "Favourite"

        readButton.bezelStyle = .inline
        readButton.isBordered = false
        readButton.contentTintColor = .tertiaryLabelColor
        readButton.target = self
        readButton.action = #selector(readPressed)
        readButton.translatesAutoresizingMaskIntoConstraints = false
        readButton.toolTip = "Mark as read"

        container.addSubview(card)
        card.addSubview(typeBadge)
        card.addSubview(dateLabel)
        card.addSubview(titleLabel)
        card.addSubview(authorLabel)
        card.addSubview(statusDot)
        card.addSubview(statusLabel)
        card.addSubview(menuButton)
        card.addSubview(starButton)
        card.addSubview(readButton)

        card.leadingAnchor.constraint(equalTo: container.leadingAnchor).isActive = true
        card.trailingAnchor.constraint(equalTo: container.trailingAnchor).isActive = true
        card.topAnchor.constraint(equalTo: container.topAnchor).isActive = true
        card.bottomAnchor.constraint(equalTo: container.bottomAnchor).isActive = true

        typeBadge.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12).isActive = true
        typeBadge.topAnchor.constraint(equalTo: card.topAnchor, constant: 11).isActive = true
        typeBadge.widthAnchor.constraint(equalToConstant: 40).isActive = true
        typeBadge.heightAnchor.constraint(equalToConstant: 15).isActive = true

        menuButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10).isActive = true
        menuButton.centerYAnchor.constraint(equalTo: typeBadge.centerYAnchor).isActive = true
        menuButton.widthAnchor.constraint(equalToConstant: 18).isActive = true
        menuButton.heightAnchor.constraint(equalToConstant: 18).isActive = true

        starButton.trailingAnchor.constraint(equalTo: menuButton.leadingAnchor, constant: -2).isActive = true
        starButton.centerYAnchor.constraint(equalTo: typeBadge.centerYAnchor).isActive = true
        starButton.widthAnchor.constraint(equalToConstant: 18).isActive = true
        starButton.heightAnchor.constraint(equalToConstant: 18).isActive = true

        dateLabel.trailingAnchor.constraint(equalTo: starButton.leadingAnchor, constant: -6).isActive = true
        dateLabel.centerYAnchor.constraint(equalTo: typeBadge.centerYAnchor).isActive = true

        titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12).isActive = true
        titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12).isActive = true
        titleLabel.topAnchor.constraint(equalTo: typeBadge.bottomAnchor, constant: 8).isActive = true

        authorLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12).isActive = true
        authorLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12).isActive = true
        authorLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2).isActive = true

        statusDot.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12).isActive = true
        statusDot.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor).isActive = true
        statusDot.widthAnchor.constraint(equalToConstant: 6).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 6).isActive = true

        statusLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 6).isActive = true
        statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: readButton.leadingAnchor, constant: -8).isActive = true
        statusLabel.topAnchor.constraint(greaterThanOrEqualTo: authorLabel.bottomAnchor, constant: 6).isActive = true
        statusLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -11).isActive = true

        readButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10).isActive = true
        readButton.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor).isActive = true
        readButton.widthAnchor.constraint(equalToConstant: 18).isActive = true
        readButton.heightAnchor.constraint(equalToConstant: 18).isActive = true

        view = container
    }

    func configure(with document: LibraryDocument) {
        typeBadge.stringValue = document.typeLabel
        dateLabel.stringValue = document.dateLabel
        titleLabel.stringValue = document.title
        authorLabel.stringValue = document.author.isEmpty ? document.filename : document.author

        let statusText: String
        let colour: NSColor
        if document.isReady {
            statusText = document.savedLabel ?? "ready"
            colour = Palette.green
        } else if document.isFailed {
            statusText = "failed"
            colour = Palette.rose
        } else if document.isBusy {
            statusText = document.status
            colour = Palette.gold
        } else {
            statusText = document.status
            colour = .tertiaryLabelColor
        }
        statusLabel.stringValue = statusText
        statusDot.layer?.backgroundColor = colour.cgColor

        // The badge takes the colour of the file type, so the grid reads at a
        // glance: violet for a book, blue for a paper.
        let typeColour = Palette.colour(forFileType: document.fileType)
        typeBadge.textColor = typeColour
        typeBadge.layer?.backgroundColor = Palette.wash(typeColour, amount: 0.15).cgColor

        // Favourite and read state come from the suite's own memory, not
        // from the backend, so they are true even for documents that have
        // not finished synthesising.
        let learning = LearningStore.shared
        let isFavourite = learning.isFavourite(documentId: document.id)
        starButton.image = NSImage(systemSymbolName: isFavourite ? "star.fill" : "star",
                                   accessibilityDescription: isFavourite ? "Remove favourite" : "Favourite")
        starButton.contentTintColor = isFavourite ? Palette.gold : .tertiaryLabelColor

        let isRead = learning.isRead(documentId: document.id)
        readButton.image = NSImage(systemSymbolName: isRead ? "checkmark.circle.fill" : "circle",
                                   accessibilityDescription: isRead ? "Mark as unread" : "Mark as read")
        readButton.contentTintColor = isRead ? Palette.accent : .tertiaryLabelColor
    }

    @objc private func menuPressed() {
        let menu = NSMenu()
        onMenu?(menu)
        menu.popUp(positioning: nil, at: NSPoint(x: menuButton.bounds.midX, y: 0), in: menuButton)
    }

    @objc private func starPressed() {
        onToggleFavourite?()
    }

    @objc private func readPressed() {
        onToggleRead?()
    }
}

// MARK: - Filter chip

/// One of the library's filter chips.
///
/// A chip carries a label and a count, and shows itself as chosen when its
/// filter is the active one. The count is drawn as part of the title so the
/// button sizes itself correctly — a count sitting on top of the label as a
/// separate subview would need the width worked out by hand.
final class FilterChip: NSButton {
    var onPress: (() -> Void)?

    private let filter: LibraryFilter
    private var count = 0

    var isChosen: Bool = false {
        didSet { updateAppearance() }
    }

    init(filter: LibraryFilter) {
        self.filter = filter
        super.init(frame: .zero)

        font = Typography.body(weight: .medium)
        bezelStyle = .inline
        isBordered = false
        alignment = .left
        image = NSImage(systemSymbolName: filter.symbol, accessibilityDescription: nil)
        imagePosition = .imageLeading
        imageHugsTitle = true
        target = self
        action = #selector(pressed)

        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true

        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 24).isActive = true

        updateAppearance()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setCount(_ count: Int) {
        guard count != self.count else { return }
        self.count = count
        updateAppearance()
    }

    private func updateAppearance() {
        // Each filter keeps its own colour, so the row reads as four
        // different questions rather than four grey labels.
        let colour: NSColor
        switch filter {
        case .all: colour = Palette.teal
        case .favourites: colour = Palette.gold
        case .unread: colour = Palette.accent
        case .ready: colour = Palette.green
        }

        let labelColour: NSColor = isChosen ? colour : colour.withAlphaComponent(0.75)
        let countColour: NSColor = isChosen ? colour.withAlphaComponent(0.7) : .tertiaryLabelColor

        let title = NSMutableAttributedString(
            string: "\(filter.title) ",
            attributes: [
                .font: Typography.body(weight: isChosen ? .semibold : .medium),
                .foregroundColor: labelColour
            ]
        )

        if count > 0 {
            title.append(NSAttributedString(
                string: "\(count)",
                attributes: [
                    .font: Typography.caption(),
                    .foregroundColor: countColour
                ]
            ))
        }

        attributedTitle = title

        if isChosen {
            layer?.backgroundColor = Palette.wash(colour, amount: 0.15).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    @objc private func pressed() {
        onPress?()
    }
}
