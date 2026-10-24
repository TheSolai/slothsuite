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
| ⌘S | read the briefing aloud |
| ⌘R | reload the page |
| ⌘\\ | toggle the sidebar |
| ⌘⇧D | copy a diagnostics bundle (versions, ports, health, log tail) to the clipboard |

- **Drag and drop** a PDF or EPUB onto the window to import it straight away.
- **Library filtering** and a per-document delete button in the sidebar.
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
- Notes live in `~/Library/Application Support/SlothSuite/learning.json`,
  next to the configuration, and nowhere else.

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

The notes module has its own end-to-end check, because the store can be
perfectly healthy while the module is broken. It presses the real **New Note**
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
