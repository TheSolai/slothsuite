# Sloth Suite — 10 suggested improvements

Written 24 Oct 2026 against `Sources/SlothSuite.swift` (829 lines), `build.sh`, and
`~/Projects/sloth-stack.sh`. Stack verified running: 8300/8100 (SlotRead), 5173/3001 (SlothMode).

Ordered by payoff-per-effort, not by topic.

---

## 1. One `WKWebView` per app — stop reloading on every switch

**Where:** `Sources/SlothSuite.swift:318` — `select()` unconditionally calls
`webView.load(URLRequest(url: spec.url))`.

**Problem:** there is a single webview shared by both apps. Every switch re-navigates,
and clicking the app you are already on re-navigates too. The result is that all
client state is destroyed: an in-flight synthesis, an uploaded book, a drafted plan,
scroll position, an expanded deck. SlothRead's syntheses take minutes — switching
to SlothMode to check a task destroys the read you were waiting for.

**Fix:** hold one `WKWebView` per `AppSpec` in a container view, add/remove it on
switch, and keep the instance alive. Also guard `select()` so selecting the current
spec is a no-op.

**Effort:** small (~40 lines). Biggest single UX win in the file.

---

## 2. Make the stack script a real supervisor, not a one-shot launcher

**Where:** `Sources/SlothSuite.swift:49,388-391,326-331`.

**Three distinct problems:**

- `didAutoStart` is set `true` on first start (`:390`) and **never reset**. If a
  backend dies ten minutes later, nothing restarts it — the app stays broken until
  you relaunch. It is a one-shot for the whole app lifetime, not a supervisor.
- `ensureStack()` (`:388`) starts the **whole** stack if **any** backend is down. One
  dead backend relaunches all four services, including ones that were perfectly fine.
- `restartStack()` waits a **fixed 1.5 s** (`:328`) between `stop` and `start`. The
  script's own `kill_port` already sleeps and retries, so the fixed delay races port
  release and `vite --strictPort` can lose the race.

**Fix:** track readiness per service, restart only the failed one, poll for the port
to actually free instead of sleeping, and re-arm `didAutoStart` when a service dies.
Surface "could not start X — see log" instead of silently doing nothing.

**Effort:** medium. Touches the Swift side and `sloth-stack.sh` (`stop`/`start`
should take a service name and be idempotent).

---

## 3. Native library and import panel for SlothRead

**Where:** the backend already has the whole API — `backend/app/main.py:284`
`GET /api/documents`, `:373` `GET /api/documents/{id}`, `:387`
`GET /api/documents/{id}/export`, `:341` `DELETE /api/documents/{id}`.

**Problem:** today "Add a book…" delegates to a page `<input type=file>` (`:338-361`)
and the library lives entirely inside the React app. You cannot see what you have
ingested without going to the web app, and the suite shows no document list.

**Fix:** an AppKit outline/list of ingested documents in the sidebar, populated by a
plain `URLSession` call to `/api/documents`. Drag-and-drop a PDF/EPUB onto the
window to import (calls `/api/upload` directly), and a native "Reveal" that opens
the exported Markdown via `/api/documents/{id}/export`. The DOM-scraping file-input
dance disappears entirely.

**Effort:** medium. The API is already there — this is shell work, not new backend.

---

## 4. Replace DOM scraping with a real JS bridge, and show failures

**Where:** `Sources/SlothSuite.swift:349-361` (`addBook`) and `:363-376` (`exportBriefing`).

**Problem:** both actions run JavaScript that hunts the DOM — `document.querySelector('input[type=file]')`
and "first button whose text matches `/download/i`". These break silently. When the
frontend changes, the result is `"NO_DOWNLOAD_BUTTON"` written to a log file nobody
opens, and the user's click does **nothing visible**. Same for `"NO_INPUT"`.

**Fix:** add a `WKScriptMessageHandler` bridge. Each frontend exposes named commands
(`sloth.read.addBook`, `sloth.read.exportBriefing`) that post results back to
native — stable contract, no selector guessing. Whatever fails, show an `NSAlert`
or an inline error. A dead button should never be silent.

**Effort:** small-to-medium (bridge in Swift, ~15 lines per frontend).

---

## 5. Render the identity that is already defined — and make the dot mean something

**Where:** `AppSpec.tagline` (`:14`, set at `:26,:32`) and `AppSpec.dotColor` (`:17`,
`:29,:35`) are **declared and populated but never used anywhere**.

**Problem:** the sidebar shows a bare title with no context, even though every app
already carries a tagline ("Executive decks from papers & books"). The dot is
always green or red (`:469`) — the per-app `dotColor` is ignored, so the two apps are
visually identical in the sidebar. And `window.title` is hardcoded to `"Sloth Suite"`
in both places (`:108`, `:312`), so only the subtitle changes as you switch.

**Fix:** render the tagline under each row title, tint the dot with the app's colour
when healthy (red when down), and set the window title to the active app
("Sloth Suite — SlothRead"). Also give the active row a proper selection
background instead of only a font-weight change.

**Effort:** small. Mostly deleting dead fields and adding two labels.

---

## 6. Universal binary, notarization, and open-at-login

**Where:** `build.sh:32` targets `arm64-apple-macos13.0` **only**; `build.sh:49` is
ad-hoc signed (`codesign --sign -`).

**Problem:** the bundle will not launch on an Intel Mac, and ad-hoc signing means
Gatekeeper quarantines it anywhere but this machine. There is also no way to have
the suite and its stack come up at boot.

**Fix:** build both architectures (`swift build --arch arm64 --arch x86_64` + `lipo`,
or two `swiftc` invocations into a universal binary) and broaden the deployment
target. Add `SMAppService` for a user-controlled "Open at Login" toggle. If the
suite is ever shared beyond this Mac, add Developer ID signing + notarization.

**Effort:** small for universal binary + open-at-login; notarization needs an
Apple Developer account.

---

## 7. Config file instead of hardcoded paths and ports

**Where:** `Sources/SlothSuite.swift:411` — `NSHomeDirectory() + "/Projects/sloth-stack.sh"`,
and `AppSpec` hardcodes four URLs (`:27-28`, `:33-34`) and four ports.

**Problem:** the suite only works if the stack script happens to live at
`~/Projects/sloth-stack.sh` and the backends sit on exactly those ports. If the
script is missing, the code writes a line to a log and gives the user nothing
(`:412-415`). Two dev machines, a moved folder, or a port collision all break it
silently.

**Fix:** load `~/Library/Application Support/SlothSuite/config.json` (overridable by
`--config`), with the script path, per-service URL/health URL and port. Validate at
launch and show a clear "stack script not found at X — set it in config" panel
instead of failing quietly.

**Effort:** small. `Codable` + a struct per service.

---

## 8. Real logging — correct location, rotation, and an in-app viewer

**Where:** `Sources/SlothSuite.swift:57` logs to `/tmp/slothsuite.log`; the stack
logs to `/tmp/sloth-local-logs/`. `:89` constructs a **new `ISO8601DateFormatter` on
every log line**.

**Problem:** `/tmp` is periodically reaped by macOS, so a log you need after
"something went wrong yesterday" may simply be gone. The stack's own logs — the most
useful thing when a backend fails to boot — live in the same fragile place and are
not reachable from the UI at all. The per-line formatter allocation is main-thread
churn for no reason.

**Fix:** write to `~/Library/Logs/SlothSuite/`, with a size-based rotation. Hoist
the formatter to a `static let`. Add a "Show logs" button that opens
`~/Library/Logs/SlothSuite/` in Finder, plus a small in-app log viewer showing the
tail of both the suite log and the stack logs.

**Effort:** small-to-medium. The in-app viewer is the optional half.

---

## 9. Put it in version control, and pin what it was tested against

**Where:** `SlothSuite` is **not a git repository** (`git log` → no repo), while both
child apps are — and both are dirty right now:

- `SlotRead`: 7 modified files (`backend/app/config.py`, `main.py`, `parser.py`,
  `summarizer.py`, `frontend/js/api.js`, `public/js/api.js`, `src/App.tsx`) plus
  untracked `backend/storage/`.
- `SlothMode`: 3 modified (`server/index.js`, `vite.config.ts`, `package-lock.json`)
  plus untracked `SUITABILITY-SECURITY-REPORT.md`.

**Problem:** the suite is the only piece with no history, no branch, and no way back.
And it hard-depends on two other working trees that change underneath it — there is
no record of which version of SlotRead or SlothMode the suite was last good against.

**Fix:** `git init` + first commit; a `README.md` covering the ports, the stack
script contract, and `--selftest`; and record the tested child-app commits (or a
`stack.lock` with pinned SHAs) so a broken child update is traceable.

**Effort:** small. Highest durability-per-minute item in this list.

---

## 10. Make `--selftest` a real pass/fail gate

**Where:** `Sources/SlothSuite.swift:691-755`. The self-test is genuinely good —
it exercises the file picker, the upload path and the download path that no unit
test can reach. But it **always `exit(0)`** (`:749`), so it can never fail.

**Problem:** it logs observations ("stack=running", "upload-stage=Synthesizing…",
"deck-visible=true") and then always reports success. There is no assertion anywhere,
so a CI check or a `build.sh test` target built on it would pass even with a fully
broken app. The fixture is also hardcoded to
`~/Downloads/dross-books/The-Great-God-Pan-by-Arthur-Machen.epub` (`:694`).

**Fix:** turn each observation into an assertion with an expected value and exit
non-zero on failure. Parameterise the fixture (`--fixture <path>`, or use any PDF
in a temp dir). Then add a `build.sh test` target so `build.sh && build.sh test`
gates a change end to end: stack up → import → deck visible → Markdown file on disk.

**Effort:** small. The hard parts — the probe paths — already work.

---

## Bonus (if you want an 11th)

**Native macOS chrome:** `⌘1`/`⌘2` to switch apps, a Dock badge or
`UNUserNotificationCenter` alert when a long synthesis finishes while you are in the
other app, and a native toolbar. The webview gives no way to know a job ended, so a
multi-minute read can finish silently while you are elsewhere in the suite.
