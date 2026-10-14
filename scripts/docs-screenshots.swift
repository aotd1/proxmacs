// Captures the web UI screenshots in docs/ with WebKit (no browser needed):
//
//   PROXMACS_PASSWORD=… swift scripts/docs-screenshots.swift http://127.0.0.1:8006 docs \
//       [--hostname mac-mini.local] [--ssh-keys demo.pub]
//
// Point it at a Proxmacs with a few VMs (e.g. a `cli serve` with PROXMACS_SUPPORT_DIR set to a scratch
// directory). So the screenshots don't publish them, `--hostname` replaces the Mac's name and
// `--ssh-keys` the Mac's SSH public keys (offered in the Create VM dialog).
import AppKit
import WebKit

struct Shot {
    var file: String
    var hash: String
    var size = CGSize(width: 1440, height: 900)
    var dark = false
    /// Seconds to let the view load and poll; the host memory chart fills up over time (a sample every 3 s).
    var wait: Double = 2.5
    /// Task log expanded.
    var tasks = false
    /// Run after the view has loaded, e.g. to open a dialog.
    var script: String? = nil
}

let shots = [
    Shot(file: "host-summary", hash: "#/host/summary", size: CGSize(width: 1440, height: 1080), wait: 60, tasks: true),
    Shot(file: "vm-summary", hash: "#/vm/db01/summary", size: CGSize(width: 1440, height: 1400)),
    Shot(file: "vm-hardware", hash: "#/vm/db01/hardware", size: CGSize(width: 1440, height: 1100)),
    Shot(file: "vm-options", hash: "#/vm/web01/options"),
    Shot(file: "vm-cloudinit", hash: "#/vm/web01/cloudinit"),
    Shot(file: "vm-console", hash: "#/vm/web01/console", script: """
        const input = document.querySelector('.xterm-helper-textarea');
        input?.focus();
        input?.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', keyCode: 13, bubbles: true }));
        """),
    Shot(file: "vm-backups", hash: "#/vm/web01/backups"),
    Shot(file: "host-storage", hash: "#/host/storage"),
    Shot(file: "host-targets", hash: "#/host/targets"),
    Shot(file: "host-jobs", hash: "#/host/jobs"),
    Shot(file: "host-notifications", hash: "#/host/notifications"),
    Shot(file: "host-images", hash: "#/host/images"),
    Shot(file: "create-vm", hash: "#/host/summary", script: """
        [...document.querySelectorAll('.topbar .btn.primary')].find((b) => b.offsetParent)?.click();
        """),
    Shot(file: "vm-summary-dark", hash: "#/vm/web01/summary", dark: true),
    Shot(file: "mobile-vm-summary", hash: "#/vm/web01/summary", size: CGSize(width: 390, height: 844)),
    Shot(file: "mobile-menu", hash: "#/vm/web01/summary", size: CGSize(width: 390, height: 844), script: """
        document.querySelector('.nav-toggle')?.click();
        """),
]

let arguments = CommandLine.arguments
guard arguments.count >= 3, let base = URL(string: arguments[1]),
      let password = ProcessInfo.processInfo.environment["PROXMACS_PASSWORD"] else {
    FileHandle.standardError.write(Data("""
        usage: PROXMACS_PASSWORD=… swift scripts/docs-screenshots.swift <url> <dir> [--hostname NAME] [--ssh-keys FILE]

        """.utf8))
    exit(2)
}
let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
func option(_ name: String) -> String? {
    arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
}
func jsonLiteral(_ value: some Encodable) -> String { String(data: try! JSONEncoder().encode(value), encoding: .utf8)! }

/// API responses to rewrite in the page: path → JavaScript function from the parsed body to a new one.
var overrides: [String: String] = [:]
if let hostname = option("--hostname") {
    overrides["/api/host"] = "(body) => ({ ...body, hostname: \(jsonLiteral(hostname)) })"
}
if let file = option("--ssh-keys") {
    let keys = try String(contentsOfFile: file, encoding: .utf8).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    overrides["/api/host/sshkeys"] = "() => \(jsonLiteral(keys))"
}

@MainActor
final class Capturer: NSObject, WKNavigationDelegate {
    let base: URL
    let output: URL
    let window: NSWindow
    let webView: WKWebView
    private var loaded: CheckedContinuation<Void, Error>?

    init(base: URL, output: URL, overrides: [String: String]) {
        self.base = base
        self.output = output
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let scripts = configuration.userContentController
        // The window is off screen, so WebKit treats the page as hidden: the UI doesn't poll hidden pages,
        // and animation frames (which the console's terminal draws in) and CSS transitions don't run.
        scripts.addUserScript(WKUserScript(source: """
            Object.defineProperty(document, 'visibilityState', { get: () => 'visible' });
            window.requestAnimationFrame = (callback) => setTimeout(() => callback(performance.now()), 16);
            window.cancelAnimationFrame = (id) => clearTimeout(id);
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        scripts.addUserScript(WKUserScript(source: """
            const style = document.createElement('style');
            style.textContent = '*, *::before, *::after { transition: none !important; }';
            document.head.append(style);
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        if !overrides.isEmpty {
            let edits = overrides.map { "\(jsonLiteral($0)): \($1)" }.joined(separator: ", ")
            scripts.addUserScript(WKUserScript(source: """
                const edits = { \(edits) };
                const realFetch = window.fetch;
                window.fetch = async (...args) => {
                  const response = await realFetch(...args);
                  const edit = edits[new URL(String(args[0]), location.href).pathname];
                  if (!edit || !response.ok) return response;
                  const body = edit(await response.clone().json());
                  return new Response(JSON.stringify(body), { status: response.status, headers: response.headers });
                };
                """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        webView = WKWebView(frame: .zero, configuration: configuration)
        // Borderless and off screen: it still renders, but never shows up.
        window = NSWindow(contentRect: CGRect(x: -20000, y: 0, width: 1440, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
        super.init()
        webView.navigationDelegate = self
        window.contentView = webView
        window.orderFrontRegardless()
    }

    func load(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            loaded = continuation
            webView.load(URLRequest(url: url))
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { loaded?.resume(); loaded = nil }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { loaded?.resume(throwing: error); loaded = nil }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { loaded?.resume(throwing: error); loaded = nil }
    }

    func run(_ script: String, arguments: [String: Any] = [:]) async throws {
        _ = try await webView.callAsyncJavaScript(script, arguments: arguments, contentWorld: .page)
    }

    func capture(_ shot: Shot) async throws {
        window.setContentSize(shot.size)
        webView.appearance = NSAppearance(named: shot.dark ? .darkAqua : .aqua)
        try await run("localStorage.setItem('proxmacs.tasksOpen', JSON.stringify(open))", arguments: ["open": shot.tasks])
        // A fresh load per shot, so size-dependent defaults (e.g. the collapsed task log on phones) apply.
        // (The query makes it a real load: a fragment-only change would be a same-document navigation.)
        try await load(URL(string: "/?shot=\(shot.file)\(shot.hash)", relativeTo: base)!)
        try await Task.sleep(for: .seconds(shot.wait))
        if let script = shot.script {
            try await run(script)
            try await Task.sleep(for: .seconds(1.5))
        }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        let image = try await webView.takeSnapshot(configuration: configuration)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            throw NSError(domain: "screenshots", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot encode \(shot.file)"])
        }
        let file = output.appending(path: "\(shot.file).png")
        try png.write(to: file)
        print("\(file.path) \(cgImage.width)x\(cgImage.height)")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    do {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let capturer = Capturer(base: base, output: output, overrides: overrides)
        try await capturer.load(base)
        try await capturer.run("""
            const response = await fetch('/api/login', { method: 'POST', headers: { 'Content-Type': 'application/json' },
                                                         body: JSON.stringify({ password }) });
            if (!response.ok) throw new Error('login failed: ' + response.status);
            """, arguments: ["password": password])
        for shot in shots { try await capturer.capture(shot) }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }
}
app.run()
