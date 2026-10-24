import Cocoa
import Foundation

/// The suite's colours.
///
/// The wrapped app is dark and neon: a violet-blue wordmark, cyan
/// highlights, a green tick for "private on your machine" and a gold note
/// for "no key needed". The shell is a native macOS window, so it cannot
/// simply copy that — a neon palette on a light background is unreadable.
///
/// These are the same hues, tuned for a light window: colourful enough to
/// give the interface a life of its own, calm enough to read a page of text
/// in. Every colour is defined for light and dark, so the suite follows the
/// system appearance without anyone having to think about it.
enum Palette {

    // MARK: - The colours

    /// The violet-blue of the wordmark. The suite's primary colour.
    static let accent = dynamic(
        light: NSColor(srgbRed: 0.36, green: 0.31, blue: 0.80, alpha: 1),
        dark: NSColor(srgbRed: 0.62, green: 0.58, blue: 1.00, alpha: 1)
    )

    /// The cyan-teal of the old app's highlights.
    static let teal = dynamic(
        light: NSColor(srgbRed: 0.02, green: 0.53, blue: 0.60, alpha: 1),
        dark: NSColor(srgbRed: 0.20, green: 0.83, blue: 0.92, alpha: 1)
    )

    /// The green of the old app's "private on your machine" tick.
    static let green = dynamic(
        light: NSColor(srgbRed: 0.09, green: 0.52, blue: 0.30, alpha: 1),
        dark: NSColor(srgbRed: 0.30, green: 0.85, blue: 0.56, alpha: 1)
    )

    /// The gold of the old app's "no key needed" note.
    static let gold = dynamic(
        light: NSColor(srgbRed: 0.68, green: 0.45, blue: 0.03, alpha: 1),
        dark: NSColor(srgbRed: 0.98, green: 0.79, blue: 0.25, alpha: 1)
    )

    /// The rose of the old app's warnings.
    static let rose = dynamic(
        light: NSColor(srgbRed: 0.76, green: 0.19, blue: 0.29, alpha: 1),
        dark: NSColor(srgbRed: 0.98, green: 0.45, blue: 0.53, alpha: 1)
    )

    /// The blue of the old app's links.
    static let blue = dynamic(
        light: NSColor(srgbRed: 0.11, green: 0.38, blue: 0.78, alpha: 1),
        dark: NSColor(srgbRed: 0.40, green: 0.65, blue: 1.00, alpha: 1)
    )

    // MARK: - Per-module colour

    /// Each module gets its own colour, so the sidebar reads as a set of
    /// places rather than a list of grey rows.
    static func colour(forModule id: String) -> NSColor {
        switch id {
        case "library": return teal
        case "reader": return accent
        case "notes": return green
        case "review": return gold
        case "app": return blue
        default: return .secondaryLabelColor
        }
    }

    /// The colour that stands for a file type.
    static func colour(forFileType type: String) -> NSColor {
        switch type.lowercased() {
        case "epub": return accent
        case "pdf": return blue
        default: return .secondaryLabelColor
        }
    }

    /// The colour of a document's status light.
    static func colour(forStatus status: String) -> NSColor {
        switch status.lowercased() {
        case "completed", "ready": return green
        case "failed", "error": return rose
        case "processing", "synthesizing", "uploaded", "mapping": return gold
        default: return .tertiaryLabelColor
        }
    }

    // MARK: - Helpers

    /// A colour that follows the system appearance.
    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    /// A pale wash of a colour, for a selected row or a badge.
    static func wash(_ colour: NSColor, amount: CGFloat = 0.14) -> NSColor {
        colour.withAlphaComponent(amount)
    }

    /// A colour that stays legible on top of `background`.
    static func on(_ background: NSColor, light: NSColor, dark: NSColor) -> NSColor {
        dynamic(light: light, dark: dark)
    }
}

// MARK: - Tinted buttons

extension NSButton {

    /// Put the title in a colour of its own.
    ///
    /// `contentTintColor` tints a button's *image*, not its title, so a
    /// button that wants a coloured word needs an attributed title. The
    /// font has to be in the attributes as well, or the title falls back to
    /// the standard 13-point system font and loses the size it was given.
    func setColoredTitle(_ title: String, color: NSColor, font: NSFont? = nil) {
        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
        if let font { attributes[.font] = font }
        attributedTitle = NSAttributedString(string: title, attributes: attributes)
    }
}
