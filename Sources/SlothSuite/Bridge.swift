import Cocoa
import Foundation
import WebKit

/// Talks to the page inside the webview.
///
/// **Native → page.** A small shim is injected at document start. The shell
/// calls `window.__slothSuiteInvoke(id, command, payload)`; the page's
/// `window.__slothSuiteHandle(command, payload)` runs and posts the result
/// back through the `sloth` message handler. That is a stable contract,
/// unlike the old approach of hunting the DOM for `input[type=file]` and
/// "the first button whose text matches /download/i" — both of which broke
/// silently whenever the frontend changed.
///
/// **Page → native.** The same handler carries events the page pushes up
/// (progress and completion notifications).
///
/// If a page has not implemented the new handler yet, the bridge falls back
/// to the old DOM-based approach so the app keeps working.
final class Bridge: NSObject, WKScriptMessageHandler {
    enum Result {
        case success(Any?)
        case failure(String)
        /// The page does not implement this command and there is no fallback.
        case unsupported(String)
    }

    /// Page → native events, delivered on the main thread.
    var onEvent: ((String, [String: Any]) -> Void)?

    /// Pending native → page requests, keyed by request id.
    private var pending: [String: (Result) -> Void] = [:]
    /// The command each pending request is running.
    ///
    /// The page's reply carries the request id but not the command, so
    /// without this the fallback can only say "no legacy fallback" without
    /// saying which command it could not run.
    private var pendingCommands: [String: String] = [:]
    private let lock = NSLock()
    private var sequence = 0

    override init() {
        super.init()
    }

    // MARK: - Injection

    /// The shim that makes the round trip possible.
    ///
    /// It is injected at document start so it is always present, even on a
    /// page that has not been updated to the new contract yet.
    static let shim = """
    (function () {
      if (window.__slothSuite) return;

      function post(message) {
        try {
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.sloth) {
            window.webkit.messageHandlers.sloth.postMessage(message);
            return true;
          }
        } catch (err) {}
        return false;
      }

      // Reply to a native request with the result of a command.
      window.__slothSuiteInvoke = function (id, command, payload) {
        var handler = window.__slothSuiteHandle;
        if (typeof handler !== 'function') {
          post({ type: 'result', id: id, ok: false, data: null, error: 'command not implemented' });
          return;
        }
        var result;
        try {
          result = handler(command, payload || {});
        } catch (err) {
          post({ type: 'result', id: id, ok: false, data: null, error: String(err && err.message || err) });
          return;
        }
        Promise.resolve(result).then(
          function (data) {
            post({ type: 'result', id: id, ok: true, data: data === undefined ? null : data, error: null });
          },
          function (err) {
            post({ type: 'result', id: id, ok: false, data: null, error: String(err && err.message || err) });
          }
        );
      };

      // Helper the page may use to push an event up to the shell.
      window.__slothSuiteEvent = function (name, data) {
        post({ type: 'event', event: name, data: data || {} });
      };

      window.__slothSuite = {
        invoke: function (command, payload) {
          return new Promise(function (resolve) {
            var id = 'req-' + Date.now() + '-' + Math.random().toString(36).slice(2);
            var settled = false;
            window.__slothSuiteCallbacks = window.__slothSuiteCallbacks || {};
            window.__slothSuiteCallbacks[id] = function (message) {
              if (settled) return;
              settled = true;
              resolve(message);
            };
            if (!post({ type: 'request', id: id, command: command, payload: payload || {} })) {
              settled = true;
              resolve({ ok: false, error: 'bridge unavailable' });
            }
          });
        }
      };
    })();
    """

    // MARK: - Native → page

    /// Run a command in the page and wait for its result.
    func perform(_ command: String,
                 payload: [String: Any] = [:],
                 in webView: WKWebView,
                 timeout: TimeInterval = 25,
                 completion: @escaping (Result) -> Void) {
        lock.lock()
        sequence += 1
        let id = "req-\(sequence)-\(Int(Date().timeIntervalSince1970 * 1000))"
        var settled = false
        pending[id] = { result in
            guard !settled else { return }
            settled = true
            completion(result)
        }
        pendingCommands[id] = command
        pendingWebViews[id] = webView
        lock.unlock()

        let script = """
        if (typeof window.__slothSuiteInvoke !== 'function') {
          window.__slothSuiteInvoke = function (id, command, payload) {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.sloth) {
              window.webkit.messageHandlers.sloth.postMessage({ type: 'result', id: id, ok: false, data: null, error: 'command not implemented' });
            }
          };
        }
        window.__slothSuiteInvoke(\(Self.jsonString(id)), \(Self.jsonString(command)), \(Self.jsonObject(payload)));
        """

        webView.evaluateJavaScript(script) { [weak self] _, error in
            guard let error else { return }
            self?.finish(id: id, result: .failure("could not reach the page: \(error.localizedDescription)"))
        }

        // A page that never answers must not hang the caller.
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(id: id, result: .failure("timed out after \(Int(timeout))s"))
        }
    }

    private func finish(id: String, result: Result) {
        lock.lock()
        let handler = pending.removeValue(forKey: id)
        pendingWebViews.removeValue(forKey: id)
        pendingCommands.removeValue(forKey: id)
        lock.unlock()
        handler?(result)
    }

    // MARK: - Page → native

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "sloth",
              let body = message.body as? [String: Any] else { return }

        let type = (body["type"] as? String) ?? ""

        if type == "result" {
            guard let id = body["id"] as? String else { return }
            let ok = body["ok"] as? Bool ?? false
            let data = body["data"]
            let error = body["error"] as? String

            if ok {
                finish(id: id, result: .success(data))
            } else if let error, error == "command not implemented" {
                // The page has not been updated to the new bridge yet.
                legacyFallback(for: id, body: body)
            } else {
                finish(id: id, result: .failure(error ?? "the page reported a failure"))
            }
            return
        }

        if type == "event" {
            let name = (body["event"] as? String) ?? "event"
            let data = (body["data"] as? [String: Any]) ?? [:]
            DispatchQueue.main.async { [weak self] in
                self?.onEvent?(name, data)
            }
            return
        }

        if type == "request" {
            // The page asked the shell to run a command for it.
            guard let id = body["id"] as? String,
                  let command = body["command"] as? String,
                  let webView = message.webView else { return }
            let payload = (body["payload"] as? [String: Any]) ?? [:]
            perform(command, payload: payload, in: webView) { [weak self] result in
                switch result {
                case .success(let value):
                    self?.reply(id: id, ok: true, value: value, in: webView)
                case .failure(let message):
                    self?.reply(id: id, ok: false, value: message, in: webView)
                case .unsupported(let message):
                    self?.reply(id: id, ok: false, value: message, in: webView)
                }
            }
        }
    }

    /// Send a result back to a page that asked for it.
    private func reply(id: String, ok: Bool, value: Any?, in webView: WKWebView) {
        let payload = Self.jsonObject(value ?? NSNull())
        let script = """
        if (window.__slothSuiteCallbacks && window.__slothSuiteCallbacks[\(Self.jsonString(id))]) {
          var cb = window.__slothSuiteCallbacks[\(Self.jsonString(id))];
          delete window.__slothSuiteCallbacks[\(Self.jsonString(id))];
          cb({ ok: \(ok ? "true" : "false"), data: \(payload) });
        }
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// The webview each pending request belongs to.
    private var pendingWebViews: [String: WKWebView] = [:]

    // MARK: - Legacy fallback

    /// The pre-bridge behaviour, kept so an older frontend still works.
    private func legacyFallback(for id: String, body: [String: Any]) {
        let command = pendingCommands[id] ?? (body["command"] as? String ?? "")

        guard let webView = pendingWebViews[id] else {
            finish(id: id, result: .unsupported("no webview"))
            return
        }

        let script: String
        switch command {
        case "addBook":
            script = """
            (() => {
              const input = document.querySelector('input[type=file]');
              if (!input) return 'NO_INPUT';
              input.click();
              return 'CLICKED';
            })()
            """
        case "exportBriefing":
            script = """
            (() => {
              const btn = Array.from(document.querySelectorAll('button'))
                .find(b => /download/i.test(b.innerText || ''));
              if (!btn) return 'NO_DOWNLOAD_BUTTON';
              btn.click();
              return 'CLICKED';
            })()
            """
        default:
            finish(id: id, result: .unsupported("no legacy fallback for \(command)"))
            return
        }

        webView.evaluateJavaScript(script) { [weak self] value, error in
            if let error {
                self?.finish(id: id, result: .failure(error.localizedDescription))
                return
            }
            guard let text = value as? String else {
                self?.finish(id: id, result: .failure("unexpected reply"))
                return
            }
            if text == "NO_INPUT" {
                self?.finish(id: id, result: .failure("This page has no file input — update the app to the new bridge."))
            } else if text == "NO_DOWNLOAD_BUTTON" {
                self?.finish(id: id, result: .failure("This page has no export button — update the app to the new bridge."))
            } else {
                self?.finish(id: id, result: .success(text))
            }
        }
    }

    // MARK: - JSON helpers

    static func jsonString(_ string: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [string]),
              let text = String(data: data, encoding: .utf8),
              text.count >= 2 else { return "\"\"" }
        // `data` is a one-element JSON array; strip the brackets to get the
        // escaped string literal itself.
        return String(text.dropFirst().dropLast())
    }

    static func jsonObject(_ object: Any?) -> String {
        guard let object,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }
}
