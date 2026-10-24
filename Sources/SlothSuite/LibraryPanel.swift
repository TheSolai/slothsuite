import Cocoa

/// A native list of the documents SlothRead has ingested.
///
/// The library used to live entirely inside the web app, so the only way to
/// find a book again was to open the web app and look. The backend already
/// exposes `GET /api/documents`, so the shell can list them natively, filter
/// them, open one with a single click, and remove one.
final class LibraryPanel: NSView {
    var onOpen: ((String) -> Void)?
    var onDelete: ((String, String) -> Void)?

    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let placeholder = NSTextField(labelWithString: "No documents yet")

    private var documents: [[String: Any]] = []
    private var filter = ""

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        placeholder.font = .systemFont(ofSize: 10)
        placeholder.textColor = .tertiaryLabelColor

        scrollView.documentView = stack
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        scrollView.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
        scrollView.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
        scrollView.topAnchor.constraint(equalTo: topAnchor).isActive = true
        scrollView.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true

        heightAnchor.constraint(lessThanOrEqualToConstant: 190).isActive = true
        let preferred = heightAnchor.constraint(equalToConstant: 60)
        preferred.priority = .defaultLow
        preferred.isActive = true

        // The stack lives inside the scroll view's clip view. These
        // constraints are added once, here — adding them on every reload
        // would pile up duplicates and eventually make Auto Layout thrash.
        stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor, constant: 2).isActive = true
        stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor, constant: 2).isActive = true

        showPlaceholder("No documents yet")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Content

    private func showPlaceholder(_ text: String) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        placeholder.stringValue = text
        stack.addArrangedSubview(placeholder)
    }

    /// Filter the list by title, author or filename.
    func setFilter(_ query: String) {
        filter = query.trimmingCharacters(in: .whitespaces).lowercased()
        render()
    }

    /// Fetch the library from the app's API and redraw.
    func reload(spec: AppSpec?) {
        guard let spec, let base = spec.apiBase, let path = spec.libraryPath else {
            showPlaceholder("No library for this app")
            return
        }

        var request = URLRequest(url: base.appendingPathComponent(path))
        request.timeoutInterval = 5

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }

                if let error {
                    self.showPlaceholder("Library unavailable")
                    Log.shared.write("library fetch failed for \(spec.id): \(error.localizedDescription)")
                    return
                }

                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data = data,
                      let json = JSONTools.dictionary(from: data),
                      let documents = json["documents"] as? [[String: Any]] else {
                    self.showPlaceholder("Library unavailable")
                    return
                }

                self.documents = documents
                self.render()
            }
        }.resume()
    }

    private func render() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let filtered = documents.filter { document in
            guard !filter.isEmpty else { return true }
            let title = (document["title"] as? String) ?? ""
            let author = (document["author"] as? String) ?? ""
            let filename = (document["filename"] as? String) ?? ""
            return title.lowercased().contains(filter)
                || author.lowercased().contains(filter)
                || filename.lowercased().contains(filter)
        }

        guard !filtered.isEmpty else {
            showPlaceholder(documents.isEmpty ? "No documents yet" : "Nothing matches that filter")
            return
        }

        for document in filtered.prefix(12) {
            let id = (document["doc_id"] as? String) ?? ""
            let title = (document["title"] as? String) ?? (document["filename"] as? String) ?? "Untitled"
            let state = (document["status"] as? String) ?? "unknown"
            let minutes = (document["time_saved_minutes"] as? Int) ?? 0

            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 4
            row.translatesAutoresizingMaskIntoConstraints = false

            let button = NSButton(title: title.trimmed(to: 30), target: self, action: #selector(rowClicked(_:)))
            button.bezelStyle = .inline
            button.isBordered = false
            button.font = .systemFont(ofSize: 11)
            button.contentTintColor = .labelColor
            button.toolTip = title
            button.identifier = NSUserInterfaceItemIdentifier(id)

            let remove = NSButton(title: "✕", target: self, action: #selector(deleteClicked(_:)))
            remove.bezelStyle = .inline
            remove.isBordered = false
            remove.font = .systemFont(ofSize: 10)
            remove.contentTintColor = .tertiaryLabelColor
            remove.toolTip = "Remove this document from the library"
            remove.identifier = NSUserInterfaceItemIdentifier(id)

            row.addArrangedSubview(button)
            row.addArrangedSubview(remove)

            let detail = NSTextField(labelWithString: detailText(state: state, minutes: minutes))
            detail.font = .systemFont(ofSize: 9)
            detail.textColor = .tertiaryLabelColor

            stack.addArrangedSubview(row)
            stack.addArrangedSubview(detail)
        }

        if filtered.count > 12 {
            let more = NSTextField(labelWithString: "+\(filtered.count - 12) more in the app")
            more.font = .systemFont(ofSize: 9)
            more.textColor = .tertiaryLabelColor
            stack.addArrangedSubview(more)
        }
    }

    private func detailText(state: String, minutes: Int) -> String {
        switch state {
        case "completed":
            return minutes > 0 ? "ready · \(minutes) min saved" : "ready"
        case "failed":
            return "failed"
        case "processing", "queued":
            return state
        default:
            return state
        }
    }

    // MARK: - Actions

    @objc private func rowClicked(_ sender: NSButton) {
        let id = sender.identifier?.rawValue ?? ""
        guard !id.isEmpty else { return }
        onOpen?(id)
    }

    @objc private func deleteClicked(_ sender: NSButton) {
        let id = sender.identifier?.rawValue ?? ""
        guard !id.isEmpty else { return }
        let title = documents.first { ($0["doc_id"] as? String) == id }?["title"] as? String ?? "this document"
        onDelete?(id, title)
    }
}
