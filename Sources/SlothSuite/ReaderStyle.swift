import Cocoa
import Foundation

// MARK: - One card language

/// The suite's card.
///
/// The reader, the overview band, the chapters window and the term pop-up
/// each drew their own panel — a different radius, a different wash, a
/// different hairline — so the interface looked like four programs sharing
/// a window. This is the one description of what a card is, and every panel
/// in the suite is drawn from it.
enum ReaderStyle {

    /// The corner radius of a card.
    static let radius: CGFloat = 12

    /// The corner radius of something smaller than a card: a chip, a row.
    static let smallRadius: CGFloat = 7

    /// The wash of colour behind a card.
    static func fill(_ accent: NSColor, amount: CGFloat = 0.07) -> NSColor {
        Palette.wash(accent, amount: amount)
    }

    /// The hairline around a card.
    static func hairline(_ accent: NSColor, amount: CGFloat = 0.30) -> NSColor {
        Palette.wash(accent, amount: amount)
    }
}

// MARK: - Drawing the card

extension NSView {

    /// Draw the suite's card.
    ///
    /// One routine, so every panel has the same corners, the same wash and
    /// the same hairline. The colours are resolved against this view's
    /// window: a layer freezes the colour it was given, so a card painted
    /// with the wrong appearance stays wrong after a light/dark switch.
    func drawReaderCard(_ rect: NSRect,
                        accent: NSColor,
                        fillAmount: CGFloat = 0.07,
                        lineAmount: CGFloat = 0.30,
                        radius: CGFloat = ReaderStyle.radius) {
        guard rect.width > 0, rect.height > 0 else { return }

        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        let fill = NSColor(cgColor: resolvedCGColor(ReaderStyle.fill(accent, amount: fillAmount)))
            ?? NSColor.clear
        fill.setFill()
        path.fill()

        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                  xRadius: radius, yRadius: radius)
        let line = NSColor(cgColor: resolvedCGColor(ReaderStyle.hairline(accent, amount: lineAmount)))
            ?? NSColor.clear
        line.setStroke()
        border.lineWidth = 1
        border.stroke()
    }
}

// MARK: - A card of its own

/// A view that *is* a card.
///
/// The card is painted rather than assembled from a background colour, so it
/// follows the system appearance, and so the same drawing can be used behind
/// the reader's text where there is no view to hang a background on.
class ReaderCardView: NSView {

    /// The colour the card is tinted with.
    var accent: NSColor = Palette.accent {
        didSet { needsDisplay = true }
    }

    /// How much of the accent the card is washed with.
    var fillAmount: CGFloat = 0.07 {
        didSet { needsDisplay = true }
    }

    /// How strongly the hairline is drawn.
    var lineAmount: CGFloat = 0.30 {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        drawReaderCard(bounds,
                       accent: accent,
                       fillAmount: fillAmount,
                       lineAmount: lineAmount)
    }
}

// MARK: - A surface

/// A view whose background is the window's own.
///
/// The colour is resolved every time the system appearance changes: a
/// layer keeps the colour it was given, so a surface painted once keeps the
/// colour of the appearance it was painted in.
final class ReaderSurfaceView: NSView {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = resolvedCGColor(NSColor.windowBackgroundColor)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = resolvedCGColor(NSColor.windowBackgroundColor)
    }
}

// MARK: - A number in a circle

/// The numbered circle in front of a takeaway.
///
/// The deck drew these as circles with the number in them. They are painted
/// rather than pasted in as an image so that they follow the system
/// appearance — an image freezes the colour it was drawn with.
final class ReaderNumberBadge: NSView {

    private let number: Int
    private let colour: NSColor

    init(number: Int, colour: NSColor) {
        self.number = number
        self.colour = colour
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSRect(x: 0, y: 0, width: 20, height: 20)
        let path = NSBezierPath(ovalIn: circle)
        (NSColor(cgColor: resolvedCGColor(colour)) ?? colour).setFill()
        path.fill()

        // The number is drawn into the same rectangle as the circle, so the
        // two cannot come apart however the badge is sized.
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let text = NSAttributedString(string: "\(number)", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style
        ])
        text.draw(in: circle)
    }
}

// MARK: - A flipped view

/// A view whose coordinates run from the top down.
///
/// AppKit's coordinates run from the bottom up, so a view that puts its
/// children out from the top has to say that it is flipped — otherwise the
/// card comes out upside down.
final class ReaderFlippedView: NSView {
    override var isFlipped: Bool { true }
}
