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

        /// The colour of the card's hairline.
        var accent: NSColor {
            switch self {
            case .takeaway: return Palette.accent
            case .tips: return Palette.green
            case .hints: return Palette.gold
            case .audio: return Palette.teal
            case .overview: return Palette.blue
            }
        }

        /// The wash behind the card.
        var fill: NSColor {
            switch self {
            case .takeaway: return Palette.wash(Palette.accent, amount: 0.06)
            case .tips: return Palette.wash(Palette.green, amount: 0.07)
            case .hints: return Palette.wash(Palette.gold, amount: 0.09)
            case .audio: return Palette.wash(Palette.teal, amount: 0.08)
            case .overview: return Palette.wash(Palette.blue, amount: 0.05)
            }
        }
    }

    var kind: Kind
    /// The characters the card covers.
    var range: NSRange
    /// The number in the badge at the start of the card, if it has one.
    var badge: Int?
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
