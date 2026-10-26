# Sloth Suite — roadmap and status

## Phase 4 — the GUI overhaul: a window you can actually use

The complaint was blunt: *"it is tiny and useless"*, then *"looks so poor,
please greatly improve gui, also fix fonts to more readable"*. Three things
were wrong, and all three turned out to be the same kind of bug.

### The window came up 573 points wide

Two separate causes, and the second one only showed up after the first was
fixed.

1. `setFrameAutosaveName` had saved a degenerate frame, and AppKit's
   autosave restores and saves whatever it is given — `minSize` is not a
   floor for an autosaved frame. The frame is now managed by hand under
   `SlothSuite.windowFrame`, and only a frame of at least 1000×680 is ever
   written or read.
2. The content view's size was **ambiguous**: the sidebar was pinned to its
   leading edge and the content to its trailing edge, but nothing said how
   wide the whole thing was. Auto Layout resolved the ambiguity to the
   smallest legal size and AppKit resized the window to match. The content
   view is now pinned to the window's content rect, and kept in step with
   `NSWindow.didResizeNotification`.

The window now opens at 1320×932, and the narrow layout was checked down to
the 1000×680 minimum.

### Nothing inside the window was being positioned

The header row rendered as a row of labels piled at the top-left corner, and
the cards were blank white rectangles. The cause: **a view with Auto Layout
constraints but `translatesAutoresizingMaskIntoConstraints` left at the
default `true` keeps its creation-time frame and is never moved by its
constraints.** `NSTextField(labelWithString:)` — the obvious way to make a
label — defaults to `true`, so every label in the suite was in that state.

The constraints were being *satisfied*, coincidentally: a label pinned to
the top-left of a container whose own frame was also at the origin looks
correct to the solver. Nothing was reported. It only became visible when
the frames were measured.

What it took to fix it, and what it turned up:

- Every constrained subview now hands over its autoresizing mask, set where
  the view is created rather than in a class initialiser, because an
  initialiser cannot see a property that is still `nil` (`addButton` is an
  implicitly unwrapped optional — touching it before it is set traps).
- The **editor's header** in the notes module was a local `NSView` that
  never got the flag, which collapsed the whole header chain and pushed the
  "no note open" placeholder off the bottom of the pane.
- The **module views** themselves (`libraryView`, `readerView`, `notesView`)
  were still on autoresizing: they happened to be the right size, so the bug
  only showed when the window was resized.
- The **audio window's script** was a wrapping label whose intrinsic width
  is the whole unwrapped line — thousands of points — which pushed the
  window out to 3985 points wide.

### The reader ran every paragraph together

`BriefingTextBuilder` appended each piece of text as a run, but no piece
ended its paragraph. A heading and the text under it therefore shared one
paragraph, so the heading's style applied to the whole thing and the two ran
together on one line: *"EXECUTIVE THESISThe manuscript synthesizes…"*. Every
piece now ends its own paragraph unless it is a continuation of the same
one (a list number and its text, a term and its definition).

### Readability

A shared type scale in `Typography.swift` — display 26, title 17, body 13,
reading 16.5 — applied across the sidebar, library, reader and notes. The
reading column has a proper measure and generous margins.

### Audio that is audible

The "speak" buttons synthesised a WAV and threw it away. `AudioPlayer` now
plays the bytes the Mac service returns and queues them, so **All audio**
reads the chapters one after another. The pop-out window puts every chapter
and its full spoken script on one scrollable page, each with its own Play
button.

### The backend was reading the wrong characters

The PDF reader read the raw text operands out of the content stream, which
for a PDF with a subsetted font gives the *glyph codes* — not text at all,
but a row of meaningless characters. Every PDF that was not an EPUB had a
briefing built from noise. The extraction now uses pypdf's decoded-text hook
and works out each line's position from the combined text and
transformation matrices.

That also fixed the titles. A file called `Untitled document.pdf`, saved from
Google Docs, carries that exact string as its title. Generic titles are now
treated as no title at all, and the real title is taken from the document's
own opening lines — skipping the address block a letter opens with.

## Phase 5 — colour, and the notes that never saved

The brief was *"looking good! maybe a bit more colour, like the old one but no
weird fonts, and notes didnt work."* Two things in it.

### More colour, without the weird fonts

The old web app's palette came across — the violet-blue wordmark, cyan
highlights, the green "private on your machine", the gold "no key needed",
the rose warnings, the blue links — but tuned for a light native window. Neon
on dark does not survive the move to a light background, so the same hues are
there at a weight that can be read.

The fonts did not change: everything is still the system sans.

Every colour now means something rather than just being there: the sidebar's
module icons, the library's filters and file-type badges, the reader's
headings and chips, the status dots, the notes selection, the audio chapter
numbers. They all come from one file, `Palette.swift`, so the look of the
whole suite is one edit.

**`contentTintColor` tints a button's image, not its title.** Every coloured
button title was grey until it was given an *attributed* title — with the
font in the attributes too, or the title quietly falls back to 13-point
system type.

### The thesis rule was never painted

The reader rules the pull quote with a hairline in the margin. It was drawn
correctly and never appeared, because **NSTextView clips anything drawn to the
left of its text container** — and the rule was 9 points to the left of it.
Moving the rule inside the container's indent put it exactly where the design
wanted it, and it now paints.

### The notes module: a note you typed could be lost

*"Notes didnt work."* The notes code path turned out to work — create, list,
edit, save — but only when the store was poked directly. Driving the real
controls found three things:

1. **The auto-save could never fire.** The debounce was a `Timer` on the main
   run loop. A main thread that is busy — fetching a briefing, uploading a
   document — starves that timer, and the note sat unsaved. The debounce now
   waits on a background queue, and the store writes on its own queue too, so
   a typed note reaches the disk whatever else the app is doing. The old check
   called `flushPendingSave()` directly and therefore never exercised the
   timer at all; the new one types through the editor's own insertion path and
   waits for the note to appear **in the file**.
2. **"New Note" could be swallowed.** The view adopted any empty note it
   could find, so an old note that was never written in swallowed the request:
   the same empty note opened again and the button looked dead. It now only
   adopts a note made *for this request*.
3. **A search filter could hide the note you had just made.** The filter is
   cleared when a new note starts.

Quitting also flushes the editor, and the store's file is written before the
app goes, so the last words typed are not the first words lost.

### A failed snapshot left the app running

`--snapshot` returned without exiting when it could not find the window to
render, so a failed render left a stray copy of the suite running — holding
the learning store open and uploading its own fixture into the library. Four
duplicates of the test book were in the library because of it. The snapshot
path now always stops, and has a thirty-second watchdog.

### The Mac helper asked the model questions all at once

The on-device model is a single resource, and the helper was letting every
request run against it at the same time. Two questions at once make both of
them slow — the second can take twice as long as the first — and neither is
worth the wait. The helper now gives the model **one question at a time**.

It also **loads the model when it starts**, so the first question does not
pay for the load. And the gate's `mac.chat` check now asks a plain question
("Say hello.") instead of demanding JSON: the model's own safety classifier
rejects a prompt that asks for JSON and nothing else — it reads like an
attempt to force the output — and the check was failing for a reason that had
nothing to do with the model being there.

**The model is slow on this Mac: about 45 seconds for "Hello!"** The backend
allows 180 seconds, so the Mac provider works; it is just not quick. The
gate's budget is now 240 seconds to match.

## Phase 6 — the colours that did not survive the switch

*"Make sure no bugs."* The colour work was in, the notes were fixed, and the
gate was green. But the interface was still wrong in one way that no test
could see: **switching macOS between light and dark while the app was running
left it half-dark and unreadable.** White titles on white cards.

### Why it happened

A layer keeps the colour it was given. `layer.backgroundColor = someColour.cgColor`
resolves a dynamic colour **once**, at the moment it is set, and freezes it
there. A card built in the light appearance keeps its white background after
the user switches to dark — and its title, which is an ordinary `NSTextField`
with a dynamic `textColor`, does follow the system. White text on a white
card: invisible.

Only `NotesView` was listening for the change at all. Every other view cached
its colours and never looked again.

### Three separate mistakes, each enough on its own

1. **Nothing was listening.** Only the notes view implemented
   `viewDidChangeEffectiveAppearance`. The sidebar, the library cards, the
   reader's chips and the audio window never repainted.
2. **The wrong notification.** The audio window listened for
   `NSWindow.appearanceChangeNotification`, which does not exist — it would
   not have compiled, had it been written against the real API.
3. **The colour was resolved against the wrong appearance.** This is the
   subtle one, and it is the reason a first attempt at the fix still rendered
   white cards.

`NSColor.cgColor` resolves against the **current drawing appearance**. During
an appearance change that is still the *old* one — a view that repaints itself
from `viewDidChangeEffectiveAppearance` resolves the old colour and looks as
though nothing had happened. The colour has to be resolved against an
explicit appearance, with `performAsCurrentDrawingAppearance`.

And it has to be the **window's** appearance, not the view's own. AppKit
updates the tree from the top down: when a parent is told the appearance
changed, its children still report the old one. A card refreshed by its
parent would be handed the colours of the appearance the user just left —
which is exactly what the first attempt produced, and why the library cards
stayed white while the sidebar, refreshed directly, turned dark.

### The fix

- `resolveCGColor(_:in:)` resolves a dynamic colour against a named
  appearance, and `NSView.resolvedCGColor(_:)` resolves it against the
  window's appearance. Every layer colour in the suite now goes through it.
- Every view that paints a layer implements `viewDidChangeEffectiveAppearance`
  and repaints itself: the sidebar, the library's cards and filter chips, the
  reader's chips and chapter pills, the notes, the content surface, and the
  audio window's chapter cards.
- The audio window's surface is its own view class, which tells the controller
  to repaint the cards when the system appearance changes.

### How it is checked

`--toggle-dark` renders the interface *after* switching the appearance at
runtime, which is the only way to see whether the views repaint themselves
rather than keeping the colours they were built with. The library, the
reader, the notes and the audio window were all rendered that way and read
correctly — dark cards, readable titles, badges and chips in their dark
variants.

## Phase 8 — the reader that looks like the deck it replaced

*"You lost the keywords that came with each chapter, 3 key terms, tips and hints,
also it looks unpro, please polish it up more like the original."*

The original was the wrapped executive deck — a dark glass card with a
chapter kicker, three numbered takeaways, an interactive glossary and a
sixty-second audio recap. The native reader had none of that. It was a
wall of grey text in a text view, and the three takeaways were a numbered
list with no weight.

### The content was never produced

The words were missing at the source. The backend asked the model for
three things per chapter — takeaways, a glossary and a spoken script —
and that was all. Key terms, keywords, tips and hints had to be asked for
before they could be shown.

The chapter brief now asks for all of them:

- **Three key terms** — the chapter's central ideas, each with a definition
  a reader could follow without the book.
- **Three to six keyword tags** — what the chapter covers.
- **Two or three tips** — what the reader could do with the chapter.
- **Two or three hints** — what is worth noticing in it.

And the glossary was cleaned up. A model asked for "technical terms" in a
chapter of running prose hands back whatever was capitalised, and the first
word of a sentence is capitalised by accident. The result was a glossary
that read "Please", "Looking" and "Doing Readings" — noise with the
authority of a definition. Terms that are common words are now dropped
rather than shown, and the brief says so.

The extractive fallback fills the new fields too, so a briefing made
without a model still has the same shape as one made with it.

### The model answers the instruction instead of the question

Asking for three key terms produced three key terms — and sometimes three
*placeholders*. The brief asks for "the central idea of this chapter", and
a small local model will hand that back verbatim as a term:

> **The central idea of this chapter, named in a few words**
> **The second central idea**
> **The third central idea**

Under a KEY TERMS heading, that looks like the app has nothing to say. So
the placeholders are recognised and dropped, and the terms are made up from
the best source that has them: the model's own terms first, then the
glossary, then the chapter's own vocabulary. A chapter always ends up with
real terms.

The same pass fixed two more things it turned up. "Please" was reaching the
reader as a key term through the chapter-text fallback, which never had the
common-word filter the model's answers went through. And "Ching" was what
"Tao Te Ching" became when the phrase rule was too strict — a name has to
survive being picked out of running prose.

### The reader now has the deck's shape

Each chapter is laid out the way the deck laid it out:

- a **kicker** — "CHAPTER 15 OF 39 · pp. Chapter 15 · ~402 words" — with a
  hairline under it;
- the **chapter title**, set large;
- the **three key takeaways**, each on its own tinted panel with a numbered
  badge in the gutter;
- the **three key terms** as chips, with the definition on hover;
- the **keyword tags** as small blue chips;
- the **glossary**, **tips** and **hints**, each on its own panel;
- the **60-second recap**, in a teal panel, quoted.

### How the panels are drawn

The briefing is one long piece of text, so that it can be searched,
selected, copied and found with ⌘F. A panel is the drawn shape *behind* a
run of that text, and the text view paints it: a rounded rectangle in the
card's colour, with a hairline border.

The badge is painted too, rather than pasted in as an image. An image
freezes the colour it was drawn with, so it would stay violet in the dark
appearance and pale grey in the light one — the exact failure this
codebase already documents in Phase 6. A painted badge follows the system
appearance because it is resolved against the window's.

The first attempt put the badge on the second line of the takeaway. The
card's rect is padded and the line fragment is not, so the two cannot be
mixed: the badge's centre comes from the line fragment, and the card's
rect only tells it where to sit across.

### The reader lost the reader's place

Two bugs, both found by looking at the reader's own data after a gate run
rather than at the code.

The self-test writes a reading position for two made-up documents while it
checks that every document keeps its own place. Writing a place also moves
the "continue reading" pointer, and the pointer is what the reader opens
next — so after a gate run the reader opened a document that was never in
the library. The test cleaned up its notes and its positions and forgot the
pointer. It now takes the whole store at the start and puts it back at the
end, so a test that was interrupted cannot leave litter in the reader's
books either.

And the reader itself lost the place. Coming back to a saved place needs
the text view to have been laid out; when it had not, the move was silently
not made, and the reader then reported the top of the book as the reader's
place. A book that had been read for days went back to "Ch 1 of 39" the
moment it was opened. The move is now checked rather than assumed — the
scroll has to have landed — and a place that could not be applied is held
until it can be, and is never reported as something else.

### Books have to be re-synthesised

The new fields are produced when a book is analysed, so a book that was
analysed before this change does not have them. The reader shows what a
book has — a briefing without key terms simply has no key terms row —
and the books in the library are being re-analysed with the new brief.

A re-analysis does not replace the book. It produces a new document, and
the new brief is copied over the existing entry under the existing id,
keeping the original date. A reader who had written a note against a book
and stopped in chapter fourteen still has both.

## Phase 9 — the reader you can follow

*"Define the chapters names more, add in the key terms ect, make sure all
buttons and back end is wired up, also the key terms should be one word, the
a hover over pop up that give the rest of the meaning. Also the keywords
should be clickable and linked to the other key words — add a word cloud and
stats to this."*

The terms in a book were labels. They were printed and could not be followed,
so a reader who wanted to know where a word was used had to read every
chapter to find out.

### A chip is one word, and the pop-up has the rest

"Personal Day Card" is a good name for a term and a bad shape for a chip: it
wraps, it takes the reader's eye off the page it is on, and three of them in
a row leave a ragged edge. The chip now carries the first word and the
popover carries the rest — the whole term in a serif face, what it means, and
the other chapters that use it.

The popover is a real `NSPopover` rather than the `NSToolTip` attribute the
reader used before. The attribute is documented for `NSTextView`, but it was
never seen working, and a definition the reader cannot open is not a
definition.

### Keywords that lead to the other key words

A keyword is now a link. Clicking one opens a pop-up with every chapter that
uses the word and the key terms whose definitions talk about it, and every
row in it is a jump: the reader goes to the chapter and the term is flashed
in gold, so they can see where they landed instead of having to look for it.

A jump that moves the page without saying so is worse than no jump at all.

### The Overview band

The numbers that describe a book were at the top of a long scroll, which
means they are only there when the reader has just started. They are now in
a band under the title, with the book's key terms, its keywords, its
most-discussed term, and a word cloud of the words it keeps coming back to.
Every word in the cloud is a way in.

### Names, and what is not a chapter

Front matter is the book's furniture. A copyright page is not a chapter, and
when it was treated as one it got its own key terms, its own sixty-second
recap, and a line in the chapter list that said "First available in this
edition 2016". Copyright pages, title pages and tables of contents are now
skipped when an EPUB is parsed.

A chapter also has to be *named*. "Introduction", "Chapter 4" and "Part I"
say where a chapter is rather than what is in it, so the model is asked for a
name in the chapter's own vocabulary, and the book's own heading is used
when it is better than the model's.

Dropping the front matter moves every chapter after it up by one, so the
place a reader had stopped reading is moved with it — matched by the
chapter's title, not by its number.

### Three layout bugs, all silent

The band, the chips and the pop-up all went in at once, and the first
snapshot showed a reader with no text in it and a header 850 points tall.

- **The band kept its autoresizing mask.** Auto Layout ignores the
  constraints of a view that still has one, so the band stayed at 0×0 and
  everything that hung off it went with it. Nothing is logged when this
  happens.
- **The header's height became ambiguous.** It used to be known from the
  row of chips under the title. Once the chapter bar hung off the band
  instead, nothing pinned it, and Auto Layout resolves an ambiguous height
  by stretching the view over the whole page.
- **The chapters window had been broken all along.** Its labels were direct
  subviews of the card but still had their autoresizing masks, so every
  constraint was ignored and the whole window drew on top of itself. The
  window was 264 points wide because assigning a content view with no frame
  took the window's size from the view's — which was nothing.

### How it is checked

`reader.chips` checks that every chip is one word and still knows its term
and definition. `reader.follows` clicks a keyword and checks that the reader
landed on a chapter and flashed the term. Both are in the gate.

## Phase 10 — the reader you can see

*"These are so different, I don't want cursive writing, but look at how the
1st screen is so cramped. 'Exactly 3 High-Impact Takeaways' is missing — why
did you lose this? The reader isn't using enough of the screen, there should
also be the option to pop it out. Remove the hacktober stuff and unify the
graphics in the gui."*

Three things were wrong at once: the reader was a narrow column floating in
the middle of a wide window, the deck's own words were missing from it, and
the web app was wearing an event's branding and a brush-script font.

### The column takes the space it is given

The reader's text was capped at 660 points inside a 1036-point area, so a
third of the window was empty on both sides of the column. The reading column
is now as wide as it should be — around 700 points of text — and the rest of
the width is a rail.

The split is worked out by hand rather than by Auto Layout, because how much
each side gets depends on how wide the window is and Auto Layout cannot
decide that without being told. Below 640 points of column the rail goes
away rather than squeezing the text.

### The rail says the deck's three things

The wrapped deck opened with three cards: the rule of three, the interactive
glossary and the spoken recap. The native reader has the same three things,
so it says the same three things — in the deck's own words, including
"Exactly 3 High-Impact Takeaways" and the line about there being no
wall-of-text fatigue.

But the cards are live. Each one shows the chapter that is on screen: the
chapter's three takeaways, the chapter's key terms as chips, and a button
that reads the chapter aloud. The sound card says the Mac's own voice rather
than a cloud one, because the suite is offline and promising a fallback it
does not have would be a lie told in a footnote.

### The reader can be popped out

The **Pop out** button opens the reader in a window of its own. It is not a
picture of the reader — it is a second reader on the same book, and the two
are kept in step: when one moves to another place, the other follows.

### One card language

The reader, the band of numbers at the top, the chapters window and the
pop-up over a term now draw their panels from one routine. One radius, one
wash, one hairline, and the same numbered circles. The band used to be a
white panel on a white window — a panel you could not see.

### The web app: no brush script, no event

The deck was wearing Alex Brush, a brush script, for its display headings and
Caveat, a handwriting face, for its annotations. Neither is fetched any more,
which matters: they were requests to fonts.googleapis.com, and the suite's
promise is that it works with no network at all. The script face now falls
back to the serif that was already loaded and the handwriting face to the
sans.

"Hacktoberfest" is gone from every file in the web app: the nav link, the
badge over the hero, the footer, the author byline, the audience line, the
blurb and the backend's own export. The event's name is replaced by the
International Sloth Day, which is the thing the app was actually made for.

### Two bugs worth writing down

- **A label with no stated height is a height something else decides.** The
  rail's cards were laid out by hand at first, and a label whose text wraps
  has no intrinsic height — so Auto Layout took over and gave every one of
  them its intrinsic size: one line, as wide as the text, all at the same
  place. The fix was to measure the text at the width it would be given and
  make the measurement a constraint.
- **A place must say which book it belongs to.** The pop-out is a second
  reader, and a report from it used to be written against whichever document
  the suite happened to have open. Now every place carries its document, so a
  report from one reader cannot overwrite another book's place.

The pop-up over a term was also 0 × 0 — it had a frame of its own, so its
constraints were ignored and it was never given a size. It had been broken
before this phase and nothing caught it, because nothing had ever captured
it.

### How it is checked

`reader.pillars` checks that the rail carries the deck's three headings.
`reader.width` checks that the column fills the space it is given — 72% of
the reader's area at 1320 points wide. `reader.popout` opens the reader's own
window and closes it again. All three are in the gate.

## Phase 7 — the fourth ten: a learning desk that remembers

*"Now make 10 QoL improvements."* Every one of these was a gap found by
reading the code rather than by using it — things the suite did not do, or
did not do where the user would look for them.

1. **The reader puts you back where you were.** The chapter was recorded and
   never used: `show(briefing:)` set the chapter to zero every single time.
   Now the reader opens at the chapter you left.
2. **Every document keeps its own place.** Only the last document's position
   was remembered, so reading a second book lost your place in the first.
   Positions are now per document.
3. **The place includes the line.** The scroll is remembered as a fraction of
   the chapter, so it lands in the same *line*, not just the same chapter,
   and survives a change of window size.
4. **A note remembers the chapter it came from.** A note taken in the reader
   records the chapter, and opening it from the note list goes straight
   there.
5. **The library card says where you got to.** "Ch 3 of 10", so a half-read
   book does not look like an unread one.
6. **The library can be put in order.** Recent, Title, Author or Longest.
   Favourites float to the top in the default order, and not when an order
   has been asked for.
7. **Everything can be marked read at once** — and unmarked again.
8. **The notes come out as Markdown.** File ▸ Export Notes…, grouped by the
   document each note came from.
9. **The Review module exists.** The sidebar had been holding a place for it
   since the beginning. Spaced repetition over your own notes: the first line
   is the prompt, the rest is the answer, and the schedule decides when it
   comes back.
10. **The suite watches the Mac helper.** It could wedge — the on-device
    model is a single resource — and the user had to notice and restart by
    hand. Now two failures in a row restart it.

### The bug the watchdog found by accident

The Review module's layout would not lay out. The heading was 828 points
tall and the count label sat in the middle of the window, and no Auto Layout
warning was printed.

The cause was the trap this codebase already documents: **a view that keeps
its autoresizing mask is never moved by its constraints.** The progress bar
had lost its `translatesAutoresizingMaskIntoConstraints = false` when the
view was rewritten, so it kept the 0×0 frame it was made with — and
everything anchored to it landed in the wrong place. The fix was one line;
finding it took a probe, because the symptom pointed at the whole view tree
rather than at one small view.

The lesson is in `NotesView.swift` already, in a comment above a helper
called `handOverToAutoLayout`. It is worth reading before laying out a new
view here.

## Phase 3 — the third ten: a learning desk, not a shell

The brief was a redesign: functional buttons, a real library, and the old
sidebar clutter gone. The suite stopped being a wrapper around one web app
and became a set of native modules with the app as the engine behind them.

| # | improvement | where |
|---|---|---|
| 1 | Native **Reader** — briefings rendered in the app, not in a web page | `ReaderView.swift` |
| 2 | Native **Notes** — notes anchored to documents, stored on this machine | `NotesView.swift`, `LearningStore.swift` |
| 3 | Library filters — All / Favourites / Unread / Ready, each with a count | `LibraryView.swift` |
| 4 | Favourites — star a document, it floats to the top of the library | `LearningStore.swift` |
| 5 | Read state — mark what you have read, and filter by it | `LearningStore.swift` |
| 6 | Continue reading — pick up the last document at the chapter you left | `LearningStore.swift` |
| 7 | Find in briefing — a native find bar over the whole briefing | `ReaderView.swift` |
| 8 | Live command palette — searches documents and notes as you type | `CommandPalette.swift` |
| 9 | Keyboard shortcuts — ⌘1–⌘5, ⌘L, ⌘F, ⌘N, ⌘O, ⌘E, ⌘S, plus a shortcut sheet | `SuiteController.swift` |
| 10 | Card actions — add a note, favourite, mark as read, all from the card | `LibraryView.swift` |

### The layout bug the redesign exposed

The first cut of the redesign left the content area squeezed into a narrow
column with a wide empty space to its right. The cause was the root view: a
horizontal `NSStackView` whose second arranged subview was a bare `NSView`.
A view with no intrinsic content size gives the stack nothing to distribute
width by, so it took a minimal width and left the rest of the window empty.
The root is now a plain view with explicit constraints.

The same bug showed up as a runtime warning — `UICollectionViewFlowLayout`
complaining that a 268pt card was wider than the collection view — which
proved the content area really was narrow rather than merely looking it. The
card grid is now laid out by `LibraryGridLayout`, which divides the width
into equal columns and computes exact frames, so cards never stretch.

### Modules

| module | what it is |
|---|---|
| Library | every document on this machine, as cards |
| Reader | the briefing, rendered natively, with find and listen |
| Notes | notes you wrote, attached to the documents they came from |
| Review | reserved for spaced repetition |
| App | the wrapped SlothRead web app — the synthesis engine |

## Phase 1 — the ten improvements

All ten are implemented. The self-test gate (`./build.sh test`) exercises
them and exits non-zero if any regress.

| # | improvement | where |
|---|---|---|
| 1 | One `WKWebView` per app — switching no longer reloads | `SuiteController.swift` |
| 2 | Stack supervisor: restarts only the dead service, waits for ports | `StackManager.swift` |
| 3 | Native library panel fed by `GET /api/documents` | `LibraryPanel.swift` |
| 4 | Message-handler bridge replaces DOM scraping; failures surface | `Bridge.swift` |
| 5 | Taglines, per-app dot colours, a window title that says which app | `Sidebar.swift` |
| 6 | Universal arm64 + x86_64 binary; `SMAppService` open-at-login | `build.sh`, `SuiteController.swift` |
| 7 | Config file for the stack script, URLs and ports | `Config.swift` |
| 8 | Logs in `~/Library/Logs` with rotation and a reused formatter | `Log.swift` |
| 9 | Version control, a README, pinned child-app commits | this repo |
| 10 | Self-test asserts and exits non-zero; usable as a build gate | `SelfTest.swift` |

### Bugs the gate caught

Building the gate found four real defects that had been invisible:

1. **A broken tilde expansion.** `NSHomeDirectory() + String(path.dropFirst(2))`
   produced `/Users/amreProjects/sloth-stack.sh` — no slash — so the stack
   script was never found.
2. **A one-shot auto-start.** `didAutoStart` was set once and never reset,
   so a backend that died later stayed dead.
3. **A deallocated self-test runner.** `SelfTestRunner(controller:).begin()`
   created a temporary; every `[weak self]` continuation inside it was nil,
   so the run stopped silently and hung.
4. **A GUI app's minimal PATH.** The shell launches `sloth-stack.sh` from a
   GUI app, which inherits `/usr/bin:/bin` with no Homebrew — so `node` and
   `npx` were not found and "Restart stack" silently failed. The script now
   resolves them to absolute paths.

## Phase 2 — the second ten, plus the Mac

### Removed

- **SlothMode.** Dropped from the suite, the config (with a migration for
  existing config files), and the stack script.

### Added

- **Mac as an AI provider.** A bundled helper, `mac-service`, exposes
  Apple's on-device foundation model over `http://127.0.0.1:8199`. The
  backend can summarise with it instead of Ollama; the choice is persisted.
- **The Mac's own voice.** `AVSpeechSynthesizer` speaks the 60-second
  recaps — no API key, no payment, nothing leaves the machine. This
  replaced a direct browser call to the ElevenLabs cloud API that
  contradicted the app's own "no cloud egress" claims.
- **Export as separate files.** A folder with an executive summary, one
  file per chapter, the audio scripts and the sources — instead of one
  enormous Markdown file.

### The second ten quality-of-life improvements

| # | improvement | where |
|---|---|---|
| 1 | ⌘K command palette | `CommandPalette.swift` |
| 2 | Drag and drop a PDF/EPUB onto the window to import | `DropView.swift` |
| 3 | ⌘⇧D copies a diagnostics bundle to the clipboard | `SuiteController.swift` |
| 4 | The suite remembers which app you were using | `SuiteController.swift` |
| 5 | The webview follows the window's background colour | `SuiteController.swift` |
| 6 | Dock badge while the Mac speaks or diagnostics are copied | `SuiteController.swift` |
| 7 | The error page offers "Restart the stack", not just "Try again" | `SuiteController.swift` |
| 8 | Export picks a folder and reveals the result in Finder | `Exporter.swift` |
| 9 | The library filters, and documents can be deleted natively | `LibraryPanel.swift` |
| 10 | ⌘\\ toggles the sidebar | `SuiteController.swift` |

## Still open

- The **on-device model is slow** — about 45 seconds for a two-word answer on
  this Mac, and longer when the model is cold. The Mac provider works and the
  backend's 180-second budget covers it, but a briefing takes minutes rather
  than seconds. Ollama is the faster provider; the Mac one is the private one.
- The **watchdog can only restart a helper it can find.** It looks for
  whatever is holding port 8199 and checks that it really is `mac-service`
  before stopping it, so a different program on that port is left alone — but
  a helper that is wedged *and* has stopped listening altogether is only
  noticed on the next poll.
- The on-device model is slower than Ollama on a long chapter. The provider
  fallback chain handles it, but the Mac provider is best suited to short
  passages.
- DNS-rebinding TOCTOU remains a theoretical gap in the backend's SSRF
  guard: the address is checked, then the connection is made by hostname.
  Pinning the connection to the checked IP would need a custom transport.
- The ElevenLabs cloud fallback in the backend is only exercised on its
  "no key" path — there is no key to test the real API with.

## Verified

The gate (`./build.sh test`) is green at **46/46**, exit 0:

```
config.apps, config.services, stack.script, stack.ports.read,
health.read, webview.attached, page.ready, webview.url, webview.title,
bridge.status, library.documents, module.library, module.reader,
module.notes, module.review, module.app, learning.note, learning.favourite,
learning.read, learning.cleanup, notes.button, notes.create, notes.list,
notes.editor, notes.autosave, notes.survive, notes.cleanup, briefing.fetch,
web.endpoint.read, provider.endpoint, mac.service, mac.chat, mac.speak,
selftest.fixture, filepicker.fired, upload.pipeline, reader.position,
reader.persist, notes.chapter, notes.export, library.sort, library.bulk,
review.schedule, review.lapse, review.cleanup
```

The six `notes.*` checks are the end-to-end ones: the real **New Note**
button, the real insertion path, and a wait for the note to appear **in the
file on disk** — not just in the store in memory. They are the checks that
found the auto-save that could never fire.

The `review.*` and `reader.*` checks are the same kind of thing about the
new work: two documents keeping two places, the place surviving the trip to
the disk, a note keeping its chapter, the Markdown export containing the
note and its chapter, the library putting itself in order, and the review
schedule moving a note out of the way when it is remembered and bringing it
back when it is forgotten. They use ids of their own and take their litter
away again, so the user's own notes are never touched.

The gate cleans up after itself: the document it uploads is deleted again
before the run ends, so a gate that runs on every build does not leave a
copy of the fixture in the library each time.

The Mac provider path was also verified against the live stack: switching to
`mac` persists to `backend/storage/provider.json`, the on-device model
answers with valid JSON, and with the service pointed at a dead port the
backend falls back to Ollama without raising.

Audio was verified end to end: `/mac/speak` returns a 16 kHz mono WAV with
real signal (not silence), and `AVAudioPlayer` plays it — `isPlaying` is
true after half a second and the duration matches the file.

Every module was rendered and inspected with `--snapshot`, at 1320×932 and
at the 1000×680 minimum: Library, Reader, Notes, App and the pop-out audio
window.

