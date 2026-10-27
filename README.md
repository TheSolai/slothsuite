# Sloth Suite

A single native macOS window that wraps a local AI app:

| app | what it does | frontend | backend |
|---|---|---|---|
| **SlothRead** | turns papers and books into executive briefing decks | `http://127.0.0.1:8300` | `http://127.0.0.1:8100` |

The backend talks to a local Ollama daemon **or** to Apple's own on-device
model. The shell adds no cloud dependency of its own.

---

## Requirements

- macOS 13 or later for the shell (macOS 26 for the Mac services helper)
- Xcode command line tools (`xcode-select --install`) — the build uses `swiftc`
- Node 18+ (for the wrapped app)
- Python 3.11+ (for the SlothRead backend)
- Apple Silicon running macOS 26+ for the on-device model and the Mac voice

## Build and run

```bash
./build.sh          # build a universal binary and install to ~/Applications
./build.sh run      # …and launch it
./build.sh test     # …and run the self-test gate (non-zero exit on failure)
./build.sh clean    # remove build artifacts
```

`build.sh` compiles for **arm64 and x86_64** and `lipo`s them into one
binary, so the same bundle runs on an Intel Mac. The app is ad-hoc signed,
which is enough locally; sharing it with anyone else needs a Developer ID
and notarisation.

## Architecture

```
Sources/SlothSuite/
  Main.swift            entry point (@main)
  Config.swift          AppSpec, StackService, SuiteConfig, config loading
  Log.swift             rotating file log
  Support.swift         colour/path/JSON helpers
  StackManager.swift    process control, port probing, service restarts
  HealthMonitor.swift   health polling and status transitions
  Bridge.swift          the command bridge to the wrapped pages
  Modules.swift         the module list, the library model and the library store
  Sidebar.swift         functional navigation, one menu, one status line
  LibraryView.swift     the library: a card grid with filters and per-card actions
  ReaderView.swift      the native reader — a briefing, with find and listen
  NotesView.swift       the native notes module
  LearningStore.swift   favourites, read state and notes, stored locally
  Briefing.swift        the briefing model and its loader
  Typography.swift      the shared type scale
  AudioPlayer.swift     plays the synthesised audio, and queues it
  AudioWindow.swift     the pop-out window: every chapter and its script
  MacServices.swift     manages the bundled mac-service helper
  CommandPalette.swift  the ⌘K palette
  Exporter.swift        writes a briefing out as separate files
  DropView.swift        drag-and-drop document import
  SuiteController.swift the window, webviews, modules, supervisor and actions
  SelfTest.swift        assertion-based self-test
Tools/
  mac-service/          the Mac's own AI services (FoundationModels + AVSpeechSynthesizer)
```

### The modules

The suite is a learning desk with five areas, and the sidebar is generated
from one list in `Modules.swift`:

| module | what it is |
|---|---|
| **Library** | every document on this machine, as a card grid |
| **Reader** | the briefing, rendered natively, with find and listen |
| **Notes** | notes you wrote, attached to the documents they came from |
| **Review** | reserved for spaced repetition |
| **App** | the wrapped SlothRead web app — the synthesis engine |

The native modules do not need the web app running. The reader fetches the
briefing straight from the backend and renders it itself, and the notes,
favourites and read state live in
`~/Library/Application Support/SlothSuite/learning.json`.

### One webview per app

Each app gets its own `WKWebView`, kept alive and hidden when inactive.
Switching apps no longer re-navigates, so an in-flight synthesis, an
uploaded book or a drafted plan survives the switch. (The previous
single-webview design destroyed all of it on every click.)

### The supervisor

Health is polled every five seconds. When a service that was answering
stops answering, **that service** is restarted — stop, wait for its ports
to actually be released, then start. The previous behaviour started the
whole stack once at launch and never again, so a backend that died later
stayed dead.

## Configuration

The suite reads
`~/Library/Application Support/SlothSuite/config.json`, written with
sensible defaults on first run:

```json
{
  "stackScript": "~/Projects/sloth-stack.sh",
  "logDirectory": "~/Library/Logs/SlothSuite",
  "pollInterval": 5.0,
  "openAtLogin": false,
  "services": [
    { "id": "read", "label": "SlothRead", "ports": [8300, 8100] },
    { "id": "mode", "label": "SlothMode", "ports": [5173, 3001] }
  ],
  "apps": [
    {
      "id": "read",
      "title": "SlothRead",
      "tagline": "Executive decks from papers & books",
      "url": "http://127.0.0.1:8300/",
      "healthURL": "http://127.0.0.1:8100/api/health",
      "dotColorHex": "#2AA198",
      "apiBase": "http://127.0.0.1:8100",
      "libraryPath": "/api/documents",
      "service": "read"
    }
  ]
}
```

Pass `--config <path>` to use a different file. If the file is present but
unreadable the app says so and falls back to the built-in defaults rather
than failing silently.

## The stack script

`~/Projects/sloth-stack.sh` controls the local processes:

```bash
./sloth-stack.sh                    # start both services
./sloth-stack.sh start read         # start one service
./sloth-stack.sh stop mode          # stop one service
./sloth-stack.sh restart read       # restart one service
./sloth-stack.sh status             # show what is listening
```

Logs land in `~/Library/Logs/SlothSuite/stack/`. The suite's own log is
`~/Library/Logs/SlothSuite/slothsuite.log` (rotated at 1.5 MB, with the
previous version kept as `slothsuite.log.1`). "Show logs" in the sidebar
opens the folder.

## The Mac services

The suite bundles a small helper, `mac-service`, that exposes the Mac's own
intelligence over a loopback HTTP API on `http://127.0.0.1:8199`:

```
GET  /mac/status   -> {"foundationModels":"available","speech":true,"model":"apple-foundation-models"}
POST /mac/chat     -> {"system":…,"prompt":…,"json":true}  -> {"response": "…"}
POST /mac/speak    -> {"text":…,"voice":"en-GB","rate":0.5} -> audio/wav
```

It is a **separate binary** because FoundationModels needs a macOS 26
deployment target while the shell itself still supports older systems. The
suite launches it on start and stops it on quit. If the SDK is missing, the
build simply leaves it out and the suite falls back to Ollama and the
browser's own voices.

The helper binds to **127.0.0.1 only**, and it asks the model **one question
at a time** — the on-device model is a single resource, and two questions at
once make both of them slow. It also loads the model when it starts, so the
first question does not wait for it. The model takes roughly **45 seconds** to
answer on an Apple Silicon Mac, so the helper is not the fast provider: Ollama
is. The Mac provider is the private one.

Two features are built on it:

- **Mac as an AI provider.** The backend can summarise with Apple's on-device
  model instead of Ollama. Pick it in the sidebar, or with
  `POST /api/provider {"provider":"mac"}`. The choice is persisted on the
  backend, so it survives a restart.
- **The Mac's own voice.** The 60-second recaps are spoken by
  `AVSpeechSynthesizer` — no API key, no payment, and nothing leaves the
  machine. This replaced a direct browser call to the ElevenLabs cloud API,
  which contradicted the app's own "no cloud egress" claims.

## Quality-of-life

| shortcut | what it does |
|---|---|
| ⌘K | command palette — switch module, import, export, speak, restart, toggle |
| ⌘1 – ⌘5 | jump to Library, Reader, Notes, Review, App |
| ⌘L | search the library |
| ⌘F | find in the briefing |
| ⌘N | new note |
| ⌘O | add a book |
| ⌘E | export as separate files |
| ⇧⌘E | export the notes as Markdown |
| ⌘S | read the briefing aloud |
| ⌘R | reload the page |
| ⌘\\ | toggle the sidebar |
| ⌘⇧D | copy a diagnostics bundle (versions, ports, health, log tail) to the clipboard |

- **Drag and drop** a PDF or EPUB onto the window to import it straight away.
- **Library filtering** and a per-document delete button in the sidebar.
- **The library can be sorted** — recent, title, author or longest — and the
  whole library can be marked read at once.
- **The window remembers** which app you were using and reopens on it.
- **The Dock badge** shows 🔊 while the Mac is speaking and 📋 when
  diagnostics are copied.
- **The error page** offers "Restart the stack", not just "Try again".

## Audio

The briefing can be read aloud, and the shell is what plays it: the Mac
service hands back WAV bytes and `AudioPlayer` plays them through
`AVAudioPlayer`. Before this, the "speak" buttons synthesised a file and
threw it away, so the suite looked like it could read aloud and could not.

- **Listen** reads the current chapter.
- **All audio** reads every chapter, one after another, in order.
- **Chapters** opens a pop-out window with *every* chapter and its full
  spoken script on one scrollable page, each with its own Play button.

### Stopping it

A voice that cannot be stopped is a voice that reads to the end of the book,
so there is a stop wherever the voice can be started:

- a **Stop** button in the reader's header, greyed out when the suite is
  quiet and live the moment the voice starts;
- the **sound card** in the reader's rail, whose play button becomes a stop
  button while anything is being read;
- **Stop Audio** in the File menu, on **⌘.**, which works from anywhere — the
  library can start a summary talking, and the notes are where you are when
  you change your mind about it.

The stop is live the moment the speech is *asked for*, not when the audio
starts playing, so a long chapter can be called off before the Mac has
finished making it. The dock badge follows the voice: it says the suite is
speaking while it is, and it goes when it stops.

## Inspecting the interface

`screencapture` needs screen-recording permission, which a command-line
agent does not have. The shell can therefore render itself:

```bash
./build.sh
build/Sloth\ Suite.app/Contents/MacOS/SlothSuite --snapshot library:/tmp/library.png
```

`--snapshot <module>:<path>` shows a module, renders the window to a PNG and
exits. The modules are `library`, `reader`, `notes`, `app` and `audio` (the
pop-out audio window). Add `--size 1000x680` to render at the window's
smallest useful size, which is how the narrow layout is checked.

## Export as separate files

"Export as separate files…" writes a folder rather than one enormous
Markdown file: an executive summary, one file per chapter, the audio scripts
and the sources. Filenames are sanitised for the filesystem and kept unique.

## The command bridge

The shell never scrapes the DOM. A shim is injected at document start and
the page implements a single handler:

```js
window.__slothSuiteHandle = async (command, payload) => {
  // return plain JSON-serialisable data
};
```

The shell calls it and receives the result over the `sloth` message
handler. Pages may also push events up:

```js
window.__slothSuiteEvent('synthesisComplete', { title: '…' });
```

| command | app | payload | returns |
|---|---|---|---|
| `status` | both | `{}` | `{ ready, stage, title, … }` |
| `addBook` | read | `{}` | `{ ok, note }` |
| `exportBriefing` | read | `{}` | `{ ok, filename }` |
| `library` | read | `{}` | `{ documents: [...] }` |
| `openDocument` | read | `{ id }` | `{ ok }` |
| `addTask` | mode | `{}` | `{ ok, note }` |
| `exportPlan` | mode | `{}` | `{ ok, filename }` |
| `research` | mode | `{ query }` | `{ ok, results }` |

A page that has not implemented a command yet falls back to the old
DOM-based behaviour, so the shell keeps working against an older build.

## Web access

Both backends can look things up on the web — the model extracts search
queries, the backend runs them, fetches the best pages, and injects the
results into the prompt inside a clearly delimited **untrusted content**
fence.

- Endpoints: `GET /api/web/search`, `GET /api/web/fetch`, `GET /api/web/status`,
  `POST /api/web/toggle`.
- Providers are **key-free**: DuckDuckGo, Wikipedia, Crossref (plus arXiv for
  SlothRead).
- Both backends **SSRF-guard every fetch**: only `http`/`https`, every
  resolved IP checked against loopback/private/link-local/CGNAT ranges, and
  **redirects are followed manually with the check repeated on every hop** —
  a public URL cannot 302 to `127.0.0.1` and get through.
- Toggle it from the sidebar ("Enable/Disable web lookups") or per request
  with `web_research: false`.
- The sidebar no longer claims "Local · private · offline", because that
  stopped being true the moment the apps gained web access.

## Colour

The suite's colours come from the wrapped app's own palette — a violet-blue
wordmark, cyan highlights, a green tick for "private on your machine", a gold
note for "no key needed", a rose for warnings and a blue for links — but tuned
for a **light** native macOS window, because the original was neon on dark and
a neon palette on a light background is unreadable.

Every colour is defined for light and dark, so the suite follows the system
appearance. The fonts are all still the system sans: no serif, no display
faces.

Following the system is not automatic, and the reason is worth knowing if you
touch the palette. **A layer keeps the colour it was given**: setting
`layer.backgroundColor` resolves a dynamic colour once, at that moment, and
freezes it. So every view that paints a layer re-resolves its colours when
macOS changes appearance — against the *window's* appearance, because AppKit
updates the view tree from the top down and a child still reports the old
appearance while its parent is being told about the change.

`Palette.swift` has the helper for it: `resolvedCGColor(_:)` resolves a
colour against the right appearance. If you add a coloured layer, use it.

The colours are not decoration — each one means something:

| colour | what it marks |
|---|---|
| violet-blue | the suite itself, and the reader |
| cyan | the library, and the audio that is playing |
| green | the notes, a ready document, "private on your machine" |
| gold | favourites, "no key needed", work in progress |
| rose | a failure |
| blue | PDFs, links, "continue reading" |

They live in one file, `Sources/SlothSuite/Palette.swift`, so changing the
look of the whole suite is one edit.

## Notes

The notes desk is plain AppKit: a list on the left, the note on the right, and
a search box that filters as you type.

- **New Note** makes a note and puts the caret in it.
- The note **saves itself** a moment after you stop typing, and it saves
  again when you leave the module or quit the app, so nothing is lost between
  keystrokes and the disk.
- The **row menu** (⋯) opens the document the note belongs to, or deletes the
  note.
- A note made from the reader **remembers its chapter**, and opening it from
  the note list goes straight to that chapter rather than to the top.
- **File ▸ Export Notes…** (⇧⌘E) writes every note to a Markdown file,
  grouped by the document it came from.
- Notes live in `~/Library/Application Support/SlothSuite/learning.json`,
  next to the configuration, and nowhere else.

## Every book opens on its briefing

A book opens on the **Executive Briefing & Thesis** — the page the wrapped
deck showed as its first slide, in the deck's own shape:

- the strip that says *Executive Synthesis & Global Thesis · Full Manuscript
  Distillation*, with a hairline under it;
- the page title, **Executive Briefing & Thesis**;
- the **Central Argument** — the book's thesis as a pull quote on a teal panel,
  with a rule down its margin;
- the three numbers side by side — **Time Saved**, **Original Reading Time**
  and **Distillation Ratio** — each in the deck's own colour;
- the **Primary Strategic Conclusions**, one to a numbered row.

Those three numbers are painted rather than set in the text, because three
cards in a row have to share the width of the column and the column is a
different width in every window. The text leaves a band for them and the
painter fills it. The words are in the text in a colour nobody can see, so
⌘F still finds "335 min" and ⌘A still copies it.

## Reading position

The reader remembers where you were, and offers it back.

- **Every document keeps its own place.** Reading a second book no longer
  loses your place in the first.
- A book opens on its briefing, and the header carries a **Continue at
  Chapter 12** chip when there is a place to go back to. The place is offered,
  not imposed.
- The briefing is the front of the book, not a place in it, so opening a book
  never writes over the chapter you were in.
- The **chapter** is restored, and so is how far down it you had got — as a
  fraction of the chapter, so it still lands in the right place when the
  window is a different size.
- The place is saved when you leave the reader, and on a quiet moment while
  you scroll. It is written to disk but not announced, so the library and the
  notes are not redrawn on every pixel.
- The library card shows **"Ch 3 of 10"** for a document you have started, so
  a half-read book does not look like an unread one.
- The library's **Continue reading** button is the one thing that takes you
  straight back to where you were, because that is what its name says.

## The book's menu

Every card in the library has a **⋯** button, and a right-click on the card
opens the same menu:

- **Open** ⌘O
- **Send to Notes…** ⇧⌘N — the book's briefing becomes a note: the central
  argument, the executive summary, the primary conclusions and the key points,
  as plain text you can edit, and the note opens in the Notes module
- **Add a note…** — an empty note on the book
- **Speak the summary…** ⌘S
- **Export as separate files…** ⌘E
- **Favourite** ⌘D and **Mark as read** ⌘R, which say which way round they
  are for the book you are looking at
- **Remove from library** ⌘⌫

## The reader, laid out like the deck it replaced

Each chapter in the reader is laid out the way the wrapped executive deck laid
it out, and each block of the chapter has its own place on the page.

- A **kicker** — "CHAPTER 15 OF 39 · pp. Chapter 15 · ~402 words" — with a
  hairline under it, so you always know where you are in a long book.
- The **chapter title**, set large.
- The **three key takeaways**, each on its own tinted panel with a numbered
  badge in the gutter.
- The **three key terms** as chips. Hover one and the definition appears.
- The **keyword tags** — what the chapter covers — as small blue chips.
- The **glossary**, the **tips** and the **hints**, each on its own panel.
- The **60-second recap**, quoted, in a teal panel.

The briefing is still one piece of text, so it can be searched, selected,
copied and found with ⌘F. The panels and the badges are painted *behind* and
*beside* that text by the text view, which is what lets the badge follow the
system appearance: an image would freeze the colour it was drawn with.

### Where the extra content comes from

The key terms, keywords, tips and hints are produced by the model when a book
is analysed, so a book analysed before this change does not have them yet. The
reader shows what a book has — a briefing with no tips simply has no tips
panel — and the books in the library have been re-analysed to pick up the
fuller brief. A re-analysis does not replace the book: the new brief is copied
over the existing entry, so the note you wrote and the place you stopped
reading are still there.

The glossary is cleaned up on the way. A model asked for "technical terms" in
a chapter of running prose hands back whatever happened to be capitalised, and
the first word of a sentence is capitalised by accident. Common words are
dropped rather than shown, so the glossary reads "Pagan deity" instead of
"Please".

A model will also sometimes answer the *instruction* instead of the question,
and hand back "The second central idea" as a key term. Those are recognised
and dropped, and the terms are made up from the glossary and the chapter's
own vocabulary instead, so a chapter always shows real terms.

## The reader, in a window of its own

The reader can be popped out of the suite into a window of its own — the
**Pop out** button in the reader's header. A long chapter, a wide measure or a
second screen are all reasons to want the reader on its own, and the suite's
window has a sidebar, a library and a reader sharing one space.

The pop-out is not a picture of the reader. It is a second reader on the same
book, and the two are kept in step: when one of them moves to another place
in the book, the other follows it, and there is only ever one place in the
book you are at.

A place is reported with the document it belongs to. A reader in the pop-out
can be showing a different book from the one in the suite, and a report from
one of them must not be written against whichever document the other one
happens to have open — that is how a book's place ends up overwritten by
another book's.

## One card language

The reader, the band of numbers at the top, the chapters window and the
pop-up over a term all draw their panels from one routine
(`ReaderStyle.drawReaderCard`). One radius, one wash, one hairline. The
numbered circles in front of the takeaways are the same circles in the
chapters window, and they are painted rather than pasted in as images so that
they follow the system appearance.

The band at the top of the reader used to be a white panel on a white window —
a panel you could not see. It carries the numbers that describe the book, so
it is a card now.

Every panel in the suite is laid out with stated heights rather than with
frames set by hand. A label whose text wraps has no height of its own, and a
height that is not stated is a height that something else decides: the text
is measured at the width it will be given, and the measurement becomes the
constraint.

## The reader's vocabulary

A book's terms are the reader's way into it, so the reader treats them as
links rather than as labels.

- A **key term** is a chip of **one word**. "Personal Day Card" is shown as
  "Personal", because a chip long enough to wrap takes the reader's eye off
  the page it is on. Hovering the chip opens a pop-up with the whole term in a
  serif face, what it means, and **the other chapters that use it** — click
  one and the reader goes there and the term is flashed so they can see they
  landed.
- A **keyword tag** is clickable too. Clicking one opens a pop-up with every
  chapter that uses the word and **the key terms whose definitions talk about
  it**, so one word leads to the others.
- **The Overview band** at the top of the reader carries the book's figures
  — how many key terms it has, how many keywords, and its most-discussed
  term — and a **word cloud** of the words it keeps coming back to. Every word
  in the cloud is a way in: click one and the reader goes to the first
  chapter that uses it.

The pop-up is a real macOS popover, so it behaves the way a popover does:
it sits above the chip, it is dismissed by clicking away, and it follows the
light and dark appearance.

The **Chapters** button opens a window with every chapter, its full name, its
length, its key terms as chips, and its spoken script.

### Names, and what is not a chapter

A copyright page, a title page and a table of contents are the book's
furniture, not its chapters. When one was treated as a chapter it got its own
key terms, its own sixty-second recap, and a line in the chapter list called
"First available in this edition 2016". Those pages are now skipped when a
book is parsed.

A chapter also has to be *named*. "Introduction", "Chapter 4" and "Part I"
say where a chapter is, not what is in it, so the model is asked for a name
that uses the chapter's own vocabulary, and the book's own heading is used
when it is better. The chapters window shows those names in full.

## Review

The review desk is spaced repetition over your own notes. It was the one
module the sidebar had been holding a place for.

- Each note becomes a card. The **first line is the prompt** and the rest of
  the note is the answer, which stays hidden until you ask to see it.
- **Got it** moves the note further out — a day, then three, then a week,
  then a fortnight, then a month. **Again** brings it back in ten minutes,
  so it is still there before you close the app.
- A note nobody has reviewed is due straight away.
- The header says how many are due and how many are waiting for another day,
  so an empty desk does not look like an empty brain.

## The library, put in order

- The **sort control** in the header: Recent, Title, Author or Longest.
  Favourites float to the top in the default order, and not when an order
  has been asked for.
- **Mark all read** marks the whole library read — and, when everything is
  read, offers to undo that.

## The Mac services watchdog

The helper can wedge. The on-device model is a single resource and the
helper asks it one question at a time, so a request that was abandoned can
leave it waiting for ever. After that `/mac/status` still says "available",
but every model request queues behind the one that will never finish.

The suite watches for it and puts it right by itself: the helper is asked
whether it is there every 45 seconds, a model request that never comes back
counts against it, and two failures in a row restart it. The port is checked
before anything is stopped, so a different program that happened to be
listening would be left alone.

## Self-test

```bash
./build.sh test
# or, against a specific document:
./build.sh test -- --fixture ~/Documents/some-paper.pdf
```

The self-test asserts rather than merely observing: configuration, the
stack script, every service port, every health endpoint, the webview
state, the bridge round trip, the library endpoint, the web-tool
endpoints, the file picker, and finally that an upload actually reaches
the briefing deck. It exits non-zero if anything fails, so it works as a
build gate.

The voice is checked too: that the stop is greyed out when the suite is
quiet, that it comes alive when the voice starts, and that pressing it makes
the voice quiet.

A run leaves the reader's own books exactly as it found them: the whole
learning store — notes, places, favourites, read state, the "continue
reading" pointer — is taken before the first check and put back after the
last one, and the put-back is written to the disk before the process exits.

The reader's own behaviour is checked too: that a book opens on its
briefing, that the briefing is there in the deck's shape, that the card's
menu and a right-click on the card offer the same list, and that "Send to
Notes" really does make a note out of a briefing. The notes module has its
own end-to-end check, because the store can be perfectly healthy while the
module is broken. It presses the real **New Note**
button, types through the editor's own insertion path, waits for the
auto-save to land **on the disk**, and confirms the note is still there after
a trip through another module. It cleans up after itself.

## Child applications

The suite depends on two sibling working trees that change underneath it:

| app | path | pinned commit |
|---|---|---|
| SlotRead | `~/Projects/SlotRead` | `ddea21a` |
| SlothMode | `~/Projects/SlothMode` | `19d9627` |

These are the commits the suite was last verified against. Both trees also
carry uncommitted work; see `ROADMAP.md` for the state of play.
