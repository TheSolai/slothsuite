# Sloth Suite — roadmap and status

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

- The SlotRead backend's `/api/provider` and `/api/audio` endpoints are
  being finished; the self-test gate will fail until they land.
- The on-device model is slower than Ollama on a long chapter. The
  provider fallback chain handles it, but the Mac provider is best suited
  to short passages.
- DNS-rebinding TOCTOU remains a theoretical gap in both backends' SSRF
  guards: the address is checked, then the connection is made by hostname.
  Pinning the connection to the checked IP would need a custom transport.
