# Sloth Suite

A single native macOS window that wraps two local AI apps:

| app | what it does | frontend | backend |
|---|---|---|---|
| **SlothRead** | turns papers and books into executive briefing decks | `http://127.0.0.1:8300` | `http://127.0.0.1:8100` |
| **SlothMode** | gentle task planning | `http://127.0.0.1:5173` | `http://127.0.0.1:3001` |

Both backends talk to a local Ollama daemon. The shell adds no cloud
dependency of its own.

---

## Requirements

- macOS 13 or later
- Xcode command line tools (`xcode-select --install`) — the build uses `swiftc`
- Node 18+ (for the two child apps)
- Python 3.11+ (for the SlothRead backend)

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
  Sidebar.swift         app list, actions and status read-outs
  LibraryPanel.swift    native list of ingested documents
  SuiteController.swift the window, webviews, supervisor and actions
  SelfTest.swift        assertion-based self-test
```

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

## Child applications

The suite depends on two sibling working trees that change underneath it:

| app | path | pinned commit |
|---|---|---|
| SlotRead | `~/Projects/SlotRead` | `ddea21a` |
| SlothMode | `~/Projects/SlothMode` | `19d9627` |

These are the commits the suite was last verified against. Both trees also
carry uncommitted work; see `ROADMAP.md` for the state of play.
