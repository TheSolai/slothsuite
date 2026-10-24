import Cocoa
import UniformTypeIdentifiers

/// Accepts files dropped onto the window.
///
/// Dropping a PDF or EPUB onto the suite imports it straight away, instead
/// of making the user find the app's upload button and browse for the file.
final class DropView: NSView {
    /// Called with the dropped file URL.
    var onDrop: ((URL) -> Void)?

    private var highlight: NSView?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard firstSupportedURL(sender) != nil else { return [] }
        showHighlight()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        firstSupportedURL(sender) != nil ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hideHighlight()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        hideHighlight()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hideHighlight()
        guard let url = firstSupportedURL(sender) else { return false }
        onDrop?(url)
        return true
    }

    private func firstSupportedURL(_ sender: NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: options) as? [URL] else { return nil }

        return urls.first { url in
            let ext = url.pathExtension.lowercased()
            return ext == "pdf" || ext == "epub"
        }
    }

    // MARK: - Feedback

    private func showHighlight() {
        guard highlight == nil else { return }
        let border = NSView(frame: bounds)
        border.wantsLayer = true
        border.layer?.borderColor = border.resolvedCGColor(NSColor.controlAccentColor)
        border.layer?.borderWidth = 3
        border.layer?.cornerRadius = 10
        addSubview(border)
        highlight = border
    }

    private func hideHighlight() {
        highlight?.removeFromSuperview()
        highlight = nil
    }

    override func layout() {
        super.layout()
        highlight?.frame = bounds.insetBy(dx: 2, dy: 2)
    }
}
