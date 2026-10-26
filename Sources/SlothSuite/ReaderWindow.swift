import Cocoa
import Foundation

// MARK: - The pop-out window

/// The reader in a window of its own.
///
/// The suite's window has a sidebar, a library, notes and a reader all
/// sharing one space, and the reader is the one that wants room: a long
/// chapter, a wide measure, a second screen. This gives it a window.
///
/// The window holds a second reader, not a copy of the first one's pixels.
/// The two are kept in step — when one moves to another place in the book,
/// the other follows — so there is only ever one place in the book the
/// reader is at.
final class ReaderWindowController: NSObject, NSWindowDelegate {
    static let shared = ReaderWindowController()

    /// The reader in the pop-out asked to hear a chapter.
    var onSpeakChapter: ((BriefingChapter) -> Void)?
    /// The reader in the pop-out asked to hear the whole briefing.
    var onSpeakAll: ((Briefing) -> Void)?
    /// The reader in the pop-out wants the chapters window.
    var onOpenChapters: ((Briefing) -> Void)?
    /// The reader in the pop-out wants to write a note.
    var onAddNote: ((Briefing) -> Void)?
    /// The reader in the pop-out wants the wrapped app.
    var onOpenInApp: ((Briefing) -> Void)?
    /// The reader in the pop-out wants to export.
    var onExport: ((Briefing) -> Void)?
    /// The pop-out's reader moved to another chapter.
    var onChapterChanged: ((Int) -> Void)?
    /// The pop-out's reader moved to another place in the chapter.
    var onPositionChanged: ((String?, Int, Double) -> Void)?

    private var window: NSWindow?
    private let readerView = ReaderView()

    private override init() {
        super.init()

        readerView.isPopOut = true
        readerView.onSpeakChapter = { [weak self] chapter in
            self?.onSpeakChapter?(chapter)
        }
        readerView.onSpeakAll = { [weak self] briefing in
            self?.onSpeakAll?(briefing)
        }
        readerView.onOpenChapters = { [weak self] briefing in
            self?.onOpenChapters?(briefing)
        }
        readerView.onAddNote = { [weak self] briefing in
            self?.onAddNote?(briefing)
        }
        readerView.onOpenInApp = { [weak self] briefing in
            self?.onOpenInApp?(briefing)
        }
        readerView.onExport = { [weak self] briefing in
            self?.onExport?(briefing)
        }
        readerView.onChapterChanged = { [weak self] chapter in
            self?.onChapterChanged?(chapter)
        }
        readerView.onPositionChanged = { [weak self] document, chapter, scroll in
            self?.onPositionChanged?(document, chapter, scroll)
        }
    }

    // MARK: Showing

    /// Open the window for a briefing, or bring it forward if it is already
    /// open.
    func show(briefing: Briefing, opening: ReaderOpening, saved: ReadingPosition?) {
        if window == nil {
            buildWindow()
        }

        readerView.show(briefing: briefing, opening: opening, saved: saved)
        window?.title = briefing.title
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Take the window away.
    func close() {
        readerView.flushPosition()
        window?.close()
    }

    /// Is the pop-out on screen?
    var isOpen: Bool { window?.isVisible ?? false }

    /// Move the reader in the pop-out to a place.
    func follow(to chapter: Int, scroll: Double) {
        readerView.follow(to: chapter, scroll: scroll)
    }

    /// The reader in the pop-out, so it can be looked at.
    var readerViewForInspection: ReaderView { readerView }

    /// The pop-out's window, so it can be looked at.
    var windowForInspection: NSWindow? { window }

    // MARK: Window

    private func buildWindow() {
        // A real surface, so the reader has something to read against.
        let content = ReaderSurfaceView(frame: NSRect(x: 0, y: 0, width: 1240, height: 860))

        content.addSubview(readerView)
        readerView.translatesAutoresizingMaskIntoConstraints = false
        readerView.leadingAnchor.constraint(equalTo: content.leadingAnchor).isActive = true
        readerView.trailingAnchor.constraint(equalTo: content.trailingAnchor).isActive = true
        readerView.topAnchor.constraint(equalTo: content.topAnchor).isActive = true
        readerView.bottomAnchor.constraint(equalTo: content.bottomAnchor).isActive = true

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 860),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = "Reader"
        window.contentView = content
        // Assigning a content view takes the window's size from the view's
        // frame, so the size is set again afterwards to be sure of it.
        window.setContentSize(NSSize(width: 1240, height: 860))
        window.minSize = NSSize(width: 900, height: 620)
        window.delegate = self
        window.center()
        self.window = window
    }

    // MARK: Closing

    func windowWillClose(_ notification: Notification) {
        // The place is saved even if the reader is still moving when the
        // window goes.
        readerView.flushPosition()
    }
}
