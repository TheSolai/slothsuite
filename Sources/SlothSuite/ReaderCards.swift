import Cocoa
import Foundation

// MARK: - Cards

/// A block of the briefing that is drawn as a card behind the text.
///
/// The briefing is one long piece of text so that it can be searched,
/// selected, copied and found. A card is the drawn shape around a run of
/// that text: the tinted panel a takeaway sits on, the block of tips, the
/// audio recap. The text itself knows nothing about it.
struct ReaderCard: Equatable {

    enum Kind: Equatable {
        /// One of the three key takeaways.
        case takeaway
        /// What the reader could do with the chapter.
        case tips
        /// What is worth noticing in the chapter.
        case hints
        /// The spoken 60-second recap.
        case audio
        /// The whole-document overview.
        case overview
        /// The book's central argument, on its own panel.
        case thesis
        /// One of the book's primary conclusions.
        case conclusion

        /// The colour of the card's hairline.
        var accent: NSColor {
            switch self {
            case .takeaway: return Palette.accent
            case .tips: return Palette.green
            case .hints: return Palette.gold
            case .audio: return Palette.teal
            case .overview: return Palette.blue
            case .thesis: return Palette.teal
            case .conclusion: return Palette.blue
            }
        }

        /// How much of the accent the card is washed with.
        ///
        /// The wash is the same everywhere; only its strength changes with
        /// what the card holds.
        var fillAmount: CGFloat {
            switch self {
            case .takeaway: return 0.07
            case .tips: return 0.07
            case .hints: return 0.08
            case .audio: return 0.07
            case .overview: return 0.06
            case .thesis: return 0.07
            case .conclusion: return 0.05
            }
        }
    }

    var kind: Kind
    /// The characters the card covers.
    var range: NSRange
    /// The number in the badge at the start of the card, if it has one.
    var badge: Int?
}

// MARK: - The briefing numbers

/// One of the three numbers on the executive briefing.
///
/// The deck put these side by side: what the distillation saved you, what
/// the book would have taken, and how much was kept.
struct ReaderStat: Equatable {
    /// What the number is: "Time Saved".
    var label: String
    /// The number itself: "~45 min".
    var value: String
    /// A second line under the value, for the card whose value is two words.
    var detail: String?
    /// The colour of the card's hairline, and of its label.
    var accent: NSColor
}

/// The three numbers on the executive briefing, side by side.
///
/// They are painted rather than set in the text. Three cards in a row have
/// to share the width of the column, and the column is a different width in
/// every window — text laid out in a fixed position cannot follow it.
struct ReaderStatRow: Equatable {
    var stats: [ReaderStat]
    /// The band of the page the row is painted in.
    var range: NSRange
}

// MARK: - Chips

/// A term shown as a chip, with the definition that appears when it is
/// hovered over.
struct ReaderChipInfo: Equatable {
    /// The full term, as the model wrote it.
    var term: String
    /// The one word the chip actually shows.
    ///
    /// "Personal Day Card" is shown as "Personal", and the pop-up gives the
    /// rest. A chip long enough to wrap takes the reader's eye off the page
    /// it is on.
    var word: String
    var definition: String
    /// The characters the chip occupies.
    var range: NSRange
    /// The chapter it belongs to, 1-based.
    var chapter: Int
}

/// A keyword tag, which the reader can click.
struct ReaderKeywordInfo: Equatable {
    var keyword: String
    /// The characters the tag occupies.
    var range: NSRange
    /// The chapter it belongs to, 1-based.
    var chapter: Int
}
