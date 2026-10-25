import Cocoa
import Foundation

/// The suite's type scale.
///
/// There was no scale before: every view picked its own point size, and the
/// sizes drifted down to 10pt for labels that people are expected to read.
/// A learning suite is a reading tool, so the text has to be comfortable —
/// body copy at 13pt or more, secondary text at 12pt, and nothing on screen
/// smaller than 11pt unless it is a glyph.
///
/// Every size in the app comes from here, so the interface stays consistent
/// and a single change moves everything together.
enum Typography {

    // MARK: - Sizes

    /// A large screen title — the module heading.
    static let displaySize: CGFloat = 26

    /// A document or note title.
    static let titleSize: CGFloat = 17

    /// Body copy in the interface.
    static let bodySize: CGFloat = 13

    /// Supporting text: counts, dates, hints.
    static let secondarySize: CGFloat = 12

    /// The smallest readable text — a badge or a status word.
    static let captionSize: CGFloat = 11

    /// Long-form reading text.
    static let readingSize: CGFloat = 16.5

    /// A flashcard prompt — the thing you are asked to remember.
    static let promptSize: CGFloat = 21

    // MARK: - Fonts

    static func display(weight: NSFont.Weight = .bold) -> NSFont {
        .systemFont(ofSize: displaySize, weight: weight)
    }

    static func title(weight: NSFont.Weight = .semibold) -> NSFont {
        .systemFont(ofSize: titleSize, weight: weight)
    }

    static func body(weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: bodySize, weight: weight)
    }

    static func secondary(weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: secondarySize, weight: weight)
    }

    static func caption(weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: captionSize, weight: weight)
    }

    /// The font used for long-form reading.
    ///
    /// The system face at a generous size, with generous leading, is what
    /// macOS itself uses for reading — Mail, Books and Notes all do it. A
    /// serif would be a matter of taste, but a serif at a small size with
    /// tight leading is worse than a well-set sans, so the sans stays.
    static func reading(weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: readingSize, weight: weight)
    }

    /// The font used for a review prompt.
    static func prompt(weight: NSFont.Weight = .medium) -> NSFont {
        .systemFont(ofSize: promptSize, weight: weight)
    }

    /// The app's own title face.
    static func wordmark() -> NSFont {
        .systemFont(ofSize: 18, weight: .bold)
    }

    // MARK: - Paragraph style

    /// A comfortable reading paragraph: a long measure and open leading.
    static func readingParagraph() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 6
        style.paragraphSpacing = 14
        style.lineBreakMode = .byWordWrapping
        return style
    }

    /// A tight paragraph for interface text.
    static func tightParagraph() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.paragraphSpacing = 0
        return style
    }
}
