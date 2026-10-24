import Cocoa

/// Explicit entry point.
///
/// Compiled with `-parse-as-library`, so there is no implicit `main.swift`
/// top-level code to run. Without this the binary links, launches, and
/// exits instantly having done nothing.
@main
enum SlothSuiteMain {
    /// `NSApplication.delegate` is a weak reference, so the controller needs
    /// a strong owner that outlives `run()`.
    private static let controller = SuiteController()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = controller
        app.run()
    }
}
