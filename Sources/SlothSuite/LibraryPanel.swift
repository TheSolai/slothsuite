import Cocoa

/// A native list of the documents SlothRead has ingested.
///
/// The library used to live entirely inside the web app, so the only way to
/// find a book again was to open the web app and look. The backend already
/// exposes `GET /api/documents`, so the shell can list them natively and open
/// one with a single click.
final class LibraryPanel: NSView {
    var onOpen: ((String) -> Void)?

    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let placeholder = NSTextField(labelWithString: "No documents yet")

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

                self.render(documents, spec: spec)
            }
        }.resume()
    }

    private func render(_ documents: [[String: Any]], spec: AppSpec) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        guard !documents.isEmpty else {
            showPlaceholder("No documents yet")
            return
        }

        for document in documents.prefix(12) {
            let id = (document["doc_id"] as? String) ?? ""
            let title = (document["title"] as? String) ?? (document["filename"] as? String) ?? "Untitled"
            let state = (document["status"] as? String) ?? "unknown"
            let minutes = (document["time_saved_minutes"] as? Int) ?? 0

            let button = NSButton(title: title.trimmed(to: 34), target: self, action: #selector(rowClicked(_:)))
            button.bezelStyle = .inline
            button.isBordered = false
            button.font = .systemFont(ofSize: 11)
            button.contentTintColor = .labelColor
            button.toolTip = title
            button.identifier = NSUserInterfaceItemIdentifier(id)

            let detail = NSTextField(labelWithString: detailText(state: state, minutes: minutes))
            detail.font = .systemFont(ofSize: 9)
            detail.textColor = .tertiaryLabelColor

            stack.addArrangedSubview(button)
            stack.addArrangedSubview(detail)
        }

        if documents.count > 12 {
            let more = NSTextField(labelWithString: "+\(documents.count - 12) more in the app")
            more.font = .systemFont(ofSize: 9)
            more.textColor = .tertiaryLabelColor
            stack.addArrangedSubview(more)
        }

        stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor, constant: 2).isActive = true
        stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor, constant: 2).isActive = true
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

    @objc private func rowClicked(_ sender: NSButton) {
        let id = sender.identifier?.rawValue ?? ""
        guard !id.isEmpty else { return }
        onOpen?(id)
    }
}
