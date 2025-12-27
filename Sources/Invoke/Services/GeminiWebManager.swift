import Foundation
import WebKit
import Combine
import AppKit

// MARK: - InteractiveWebView
class InteractiveWebView: WKWebView {
    override var acceptsFirstResponder: Bool { return true }
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        self.window?.makeFirstResponder(self)
    }
    override func becomeFirstResponder() -> Bool { return true }
}

/// Native Gemini Bridge - v30.0 (TRUE STREAMING)
/// 核心升级：
/// 1. 支持真正的流式传输（字符级）
/// 2. 使用 MutationObserver 实时监控 DOM 变化
/// 3. 完美支持 LocalAPIServer 的 SSE 流式调用
@MainActor
class GeminiWebManager: NSObject, ObservableObject {
    static let shared = GeminiWebManager()

    @Published var isReady = false
    @Published var isLoggedIn = false
    @Published var isProcessing = false
    @Published var connectionStatus = "Initializing..."

    private(set) var webView: WKWebView!
    private var debugWindow: NSWindow?
    private var responseCallback: ((String) -> Void)?

    private struct PendingRequest {
        let prompt: String
        let model: String
        let isFromAider: Bool
        let continuation: CheckedContinuation<String, Error>
    }

    private var requestStream: AsyncStream<PendingRequest>.Continuation?
    private var requestTask: Task<Void, Never>?
    private var watchdogTimer: Timer?
    private var isCurrentRequestFromAider = false

    public static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    override init() {
        super.init()
        setupWebView()
        startRequestLoop()
    }

    deinit {
        requestTask?.cancel()
        Task { @MainActor in
            debugWindow?.close()
        }
        watchdogTimer?.invalidate()
    }

    private func startRequestLoop() {
        let (stream, continuation) = AsyncStream<PendingRequest>.makeStream()
        self.requestStream = continuation

        self.requestTask = Task { @MainActor in
            print("🔧 [Queue] Request loop started on MainActor")
            for await request in stream {
                while !self.isReady { try? await Task.sleep(nanoseconds: 500_000_000) }

                self.isCurrentRequestFromAider = request.isFromAider
                print("🚀 [Queue] Processing: \(request.prompt.prefix(15))... (isFromAider=\(request.isFromAider))")

                do {
                    let response = try await self.performActualNetworkRequest(request.prompt, model: request.model)
                    request.continuation.resume(returning: response)
                } catch {
                    print("❌ [Queue] Failed: \(error)")
                    if let err = error as? GeminiError, case .timeout = err { await self.reloadPageAsync() }
                    request.continuation.resume(throwing: error)
                }

                self.isCurrentRequestFromAider = false
            }
        }
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.applicationNameForUserAgent = "Safari"
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let userScript = WKUserScript(source: Self.injectedScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(userScript)

        let fingerprintScript = WKUserScript(source: Self.fingerprintMaskScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        config.userContentController.addUserScript(fingerprintScript)
        config.userContentController.add(self, name: "geminiBridge")

        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800), configuration: config)
        webView.customUserAgent = Self.userAgent
        webView.navigationDelegate = self

        debugWindow = NSWindow(
            contentRect: NSRect(x: 50, y: 50, width: 1100, height: 850),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        debugWindow?.title = "Fetch Debugger (v30 TRUE STREAMING)"
        debugWindow?.contentView = webView
        debugWindow?.makeKeyAndOrderFront(nil)
        debugWindow?.level = .floating

        restoreCookiesFromStorage { [weak self] in self?.loadGemini() }
    }

    func loadGemini() {
        if let url = URL(string: "https://gemini.google.com/app") { webView.load(URLRequest(url: url)) }
    }

    private func reloadPageAsync() async {
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                self.reloadPage()
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { continuation.resume() }
            }
        }
    }

    /// CRITICAL: TRUE STREAMING METHOD - Character-by-character
    @MainActor
    func streamAskGemini(prompt: String, model: String = "default", isFromAider: Bool = false, onChunk: @escaping (String) -> Void) async throws {
        print("📡 [streamAskGemini] Starting TRUE STREAMING for: \(prompt.prefix(30))...")

        guard isReady && isLoggedIn else {
            throw GeminiError.systemError("WebView not ready")
        }

        self.isProcessing = true
        self.isCurrentRequestFromAider = isFromAider
        let promptId = UUID().uuidString
        let escapedText = prompt.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: " ")

        // Inject and send the prompt using streaming bridge
        let js = "window.__streamingBridge.sendPrompt(\"\(escapedText)\", \"\(promptId)\");"
        try await webView.evaluateJavaScript(js)
        print("   ✅ Prompt injected, starting stream polling...")

        // Poll for changes every 100ms
        var lastContent = ""
        var isGenerating = true

        while isGenerating {
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms

            // Check if generation is still ongoing
            let genStatus = try await webView.evaluateJavaScript("window.__streamingBridge.isGenerating()") as? Bool ?? false

            // Get current response content
            let currentJS = "(() => { const el = window.__streamingBridge.getResponseElement(); return el ? el.innerText.trim() : ''; })()"
            let currentContent = (try await webView.evaluateJavaScript(currentJS) as? String) ?? ""

            // Calculate diff (new characters)
            if currentContent.count > lastContent.count {
                let newChars = String(currentContent.dropFirst(lastContent.count))
                if !newChars.isEmpty {
                    print("   📤 Streaming chunk: \(newChars.count) chars")
                    onChunk(newChars)
                }
                lastContent = currentContent
            }

            // Check if generation is complete
            if !genStatus && !currentContent.isEmpty {
                isGenerating = false
                print("   ✅ Stream complete: \(currentContent.count) total chars")
            }
        }

        self.isProcessing = false
        self.isCurrentRequestFromAider = false
    }

    /// Legacy blocking method (kept for compatibility)
    func askGemini(prompt: String, model: String = "default", isFromAider: Bool = false) async throws -> String {
        print("🌐 [GeminiWebManager] askGemini called: \(prompt.prefix(30))...")
        print("   isReady=\(isReady), isLoggedIn=\(isLoggedIn), isFromAider=\(isFromAider)")

        return try await withCheckedThrowingContinuation { continuation in
            let req = PendingRequest(prompt: prompt, model: model, isFromAider: isFromAider, continuation: continuation)
            if let stream = self.requestStream {
                stream.yield(req)
                print("   ✅ Request added to queue (isFromAider=\(isFromAider))")
            }
            else {
                print("   ❌ Stream not available!")
                continuation.resume(throwing: GeminiError.systemError("Stream Error"))
            }
        }
    }

    private func performActualNetworkRequest(_ text: String, model: String) async throws -> String {
        print("🔍 [performActualNetworkRequest] Starting request on thread: \(Thread.isMainThread ? "MAIN ✓" : "BACKGROUND ⚠️")")

        return try await withCheckedThrowingContinuation { continuation in
            self.isProcessing = true
            let promptId = UUID().uuidString

            print("🔍 [performActualNetworkRequest] Set up continuation for ID: \(promptId.prefix(8))")

            self.watchdogTimer?.invalidate()
            self.responseCallback = nil

            self.responseCallback = { response in
                print("📥 [performActualNetworkRequest] Callback triggered for ID: \(promptId.prefix(8))")
                self.watchdogTimer?.invalidate()
                self.isProcessing = false

                if response.hasPrefix("Error:") {
                    continuation.resume(throwing: GeminiError.responseError(response))
                } else {
                    continuation.resume(returning: response)
                }
            }

            self.watchdogTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                print("⏰ Timeout. Force scrape...")
                Task { @MainActor in
                    self?.forceScrape(id: promptId)
                }
            }

            let escapedText = text.replacingOccurrences(of: "\\", with: "\\\\")
                                  .replacingOccurrences(of: "\"", with: "\\\"")
                                  .replacingOccurrences(of: "\n", with: "\\n")

            print("📤 [GeminiWebManager] Pre-flight check:")
            print("   WebView: \(self.webView != nil ? "alive" : "nil")")
            print("   isLoading: \(self.webView.isLoading)")
            print("   URL: \(self.webView.url?.absoluteString ?? "none")")

            // Use legacy bridge for non-streaming requests
            let js = "window.__fetchBridge.sendPrompt(\"\(escapedText)\", \"\(promptId)\");"
            print("📤 [GeminiWebManager] Executing JS: sendPrompt (id=\(promptId.prefix(8))...)")

            let startTime = Date()
            self.webView.evaluateJavaScript(js) { result, error in
                let elapsed = Date().timeIntervalSince(startTime)
                print("   ⏱️ Callback fired after \(String(format: "%.3f", elapsed))s")

                if let error = error {
                    print("   ❌ JS Error: \(error.localizedDescription)")
                } else {
                    print("   ✅ JS executed successfully")
                    if let result = result {
                        print("   Result: \(result)")
                    }
                }
            }
        }
    }

    private func forceScrape(id: String) {
        let js = "window.__fetchBridge.forceFinish('\(id)');"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    enum GeminiError: LocalizedError {
        case notReady, timeout, responseError(String), systemError(String)
        var errorDescription: String? {
            switch self {
            case .notReady: return "Not ready"
            case .timeout: return "Timeout"
            case .responseError(let m): return m
            case .systemError(let m): return m
            }
        }
    }

    // MARK: - Cookie / Helper
    private static let cookieStorageKey = "FetchGeminiCookies"

    func injectRawCookies(_ cookieString: String, completion: @escaping () -> Void) {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let group = DispatchGroup()

        let cookies = parseCookieString(cookieString)

        for cookie in cookies {
            group.enter()
            store.setCookie(cookie) {
                group.leave()
            }
        }

        let cookieData = cookies.compactMap { cookie -> [String: Any]? in
            guard let properties = cookie.properties else { return nil }
            return [
                "name": cookie.name,
                "value": cookie.value,
                "domain": cookie.domain,
                "path": cookie.path
            ]
        }
        UserDefaults.standard.set(cookieData, forKey: Self.cookieStorageKey)

        group.notify(queue: .main) {
            self.reloadPage()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                completion()
            }
        }
    }

    private func parseCookieString(_ cookieString: String) -> [HTTPCookie] {
        var cookies: [HTTPCookie] = []

        if let jsonData = cookieString.data(using: .utf8),
           let jsonArray = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] {
            for item in jsonArray {
                if let cookie = parseCookieDict(item) {
                    cookies.append(cookie)
                }
            }
            return cookies
        }

        let lines = cookieString.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let parts = trimmed.components(separatedBy: ";")
            guard let firstPart = parts.first,
                  let equalIndex = firstPart.firstIndex(of: "=") else { continue }

            let name = String(firstPart[..<equalIndex]).trimmingCharacters(in: .whitespaces)
            let value = String(firstPart[firstPart.index(after: equalIndex)...]).trimmingCharacters(in: .whitespaces)

            var domain = ".google.com"
            var path = "/"

            for part in parts.dropFirst() {
                let keyValue = part.trimmingCharacters(in: .whitespaces).components(separatedBy: "=")
                if keyValue.count == 2 {
                    let key = keyValue[0].lowercased()
                    let val = keyValue[1].trimmingCharacters(in: .whitespaces)

                    if key == "domain" {
                        domain = val
                    } else if key == "path" {
                        path = val
                    }
                }
            }

            if let cookie = HTTPCookie(properties: [
                .domain: domain,
                .path: path,
                .name: name,
                .value: value,
                .secure: "TRUE"
            ]) {
                cookies.append(cookie)
            }
        }

        return cookies
    }

    private func parseCookieDict(_ dict: [String: Any]) -> HTTPCookie? {
        guard let name = dict["name"] as? String,
              let value = dict["value"] as? String else { return nil }

        let domain = dict["domain"] as? String ?? ".google.com"
        let path = dict["path"] as? String ?? "/"

        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: domain,
            .path: path,
            .name: name,
            .value: value
        ]

        if let secure = dict["secure"] as? Bool, secure {
            properties[.secure] = "TRUE"
        }

        return HTTPCookie(properties: properties)
    }

    func restoreCookiesFromStorage(completion: @escaping () -> Void) {
        guard let saved = UserDefaults.standard.array(forKey: Self.cookieStorageKey) as? [[String: Any]] else { completion(); return }
        let store = WKWebsiteDataStore.default().httpCookieStore
        let group = DispatchGroup()
        for d in saved {
            guard let n = d["name"] as? String, let v = d["value"] as? String, let dom = d["domain"] as? String, let p = d["path"] as? String else { continue }
            if let c = HTTPCookie(properties: [.domain: dom, .path: p, .name: n, .value: v, .secure: "TRUE"]) {
                group.enter(); store.setCookie(c) { group.leave() }
            }
        }
        group.notify(queue: .main) { completion() }
    }

    func reloadPage() { if let url = URL(string: "https://gemini.google.com/app") { webView.load(URLRequest(url: url)) } }

    func checkLoginStatus() {
        let js = "window.__fetchBridge ? window.__fetchBridge.checkLogin() : false;"
        webView.evaluateJavaScript(js) { [weak self] result, error in
            DispatchQueue.main.async {
                if let loggedIn = result as? Bool {
                    self?.isLoggedIn = loggedIn
                    self?.connectionStatus = loggedIn ? "🟢 Connected" : "🔴 Need Login"
                }
            }
        }
    }
}

// MARK: - Delegates
extension GeminiWebManager: WKNavigationDelegate, WKScriptMessageHandler {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.isReady = true
            self?.checkLoginStatus()
        }
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "geminiBridge", let body = message.body as? [String: Any] else { return }
        let type = body["type"] as? String ?? ""

        switch type {
        case "LOG":
            print("🖥️ [JS] \(body["message"] as? String ?? "")")
        case "GEMINI_RESPONSE":
            let content = body["content"] as? String ?? ""
            DispatchQueue.main.async { [weak self] in
                if let callback = self?.responseCallback {
                    callback(content.isEmpty ? "Error: Empty response" : content)
                    self?.responseCallback = nil
                }
            }
        case "LOGIN_STATUS":
            let loggedIn = body["loggedIn"] as? Bool ?? false
            DispatchQueue.main.async { [weak self] in self?.isLoggedIn = loggedIn; self?.connectionStatus = loggedIn ? "🟢 Connected" : "🔴 Need Login" }
        default: break
        }
    }
}

// MARK: - Injected Scripts (V30 - TRUE STREAMING)
extension GeminiWebManager {
    static let fingerprintMaskScript = """
    (function() {
        if (navigator.webdriver) { delete navigator.webdriver; }
        Object.defineProperty(navigator, 'webdriver', { get: () => undefined, configurable: true });
    })();
    """

    /// v30 - TRUE STREAMING BRIDGE with MutationObserver
    static let injectedScript = """
    (function() {
        console.log("🚀 Dual Bridge v30 (Streaming + Legacy) Initializing...");

        // ===== STREAMING BRIDGE (for LocalAPIServer) =====
        window.__streamingBridge = {
            state: 'idle',
            currentPromptId: null,
            lastSentText: '',
            responseElement: null,
            mutationObserver: null,
            isGeneratingFlag: false,

            log: function(msg) {
                console.log('[StreamBridge] ' + msg);
            },

            sendPrompt: function(text, id) {
                this.log("📤 sendPrompt: " + text.substring(0, 30) + "...");
                this.state = 'generating';
                this.currentPromptId = id;
                this.lastSentText = text.trim();
                this.isGeneratingFlag = true;

                // Inject and send
                const input = document.querySelector('div[contenteditable="true"]');
                if (!input) {
                    this.log("❌ Input not found");
                    this.state = 'idle';
                    return;
                }

                input.focus();
                input.innerText = text;
                input.dispatchEvent(new Event('input', { bubbles: true }));

                setTimeout(() => {
                    const sendBtn = document.querySelector('button[aria-label*="Send"], button[aria-label*="send"]');
                    if (sendBtn && !sendBtn.disabled) {
                        sendBtn.click();
                        this.log("✅ Sent");
                        this.startMonitoring();
                    }
                }, 300);
            },

            startMonitoring: function() {
                const self = this;

                // Find user prompt element
                setTimeout(() => {
                    self.findUserPromptElement();

                    // Start MutationObserver
                    if (self.mutationObserver) self.mutationObserver.disconnect();

                    self.mutationObserver = new MutationObserver(function(mutations) {
                        // Check if generation complete
                        const stopBtn = document.querySelector('button[aria-label*="Stop"]');
                        if (!stopBtn || stopBtn.offsetParent === null) {
                            // Stop button disappeared = generation done
                            setTimeout(() => {
                                if (!self.isGenerating()) {
                                    self.log("✅ Generation complete");
                                    self.isGeneratingFlag = false;
                                    self.state = 'complete';
                                }
                            }, 500);
                        }
                    });

                    self.mutationObserver.observe(document.body, {
                        childList: true,
                        subtree: true,
                        attributes: true
                    });
                }, 1000);
            },

            findUserPromptElement: function() {
                const searchPrefix = this.lastSentText.substring(0, 20).toLowerCase();
                const mainEl = document.querySelector('main');
                if (!mainEl) return;

                const allDivs = mainEl.querySelectorAll('div');
                for (let i = allDivs.length - 1; i >= 0; i--) {
                    const div = allDivs[i];
                    if (div.innerText && div.innerText.toLowerCase().includes(searchPrefix)) {
                        // Found user prompt, next sibling should be response
                        if (div.nextElementSibling) {
                            this.responseElement = div.nextElementSibling;
                            this.log("✅ Found response element");
                            return;
                        }
                    }
                }
            },

            getResponseElement: function() {
                if (!this.responseElement) {
                    this.findUserPromptElement();
                }
                return this.responseElement;
            },

            isGenerating: function() {
                const stopBtn = document.querySelector('button[aria-label*="Stop"]');
                return stopBtn && stopBtn.offsetParent !== null;
            }
        };

        // ===== LEGACY FETCH BRIDGE (for askGemini) =====
        window.__fetchBridge = {
            state: 'idle',
            currentPromptId: null,
            lastSentText: '',
            buttonObserver: null,
            pollInterval: null,
            graceTimeout: null,
            userPromptElement: null,
            generationStartTime: null,
            inGracePeriod: false,
            stopButtonEverSeen: false,
            lastResponseContent: null,
            lastResponseTime: 0,

            log: function(msg) {
                console.log('[FetchBridge] ' + msg);
                this.postToSwift({ type: 'LOG', message: msg });
            },

            postToSwift: function(data) {
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.geminiBridge) {
                    window.webkit.messageHandlers.geminiBridge.postMessage(data);
                }
            },

            sendPrompt: function(text, id) {
                try {
                    this.log("📤 sendPrompt called. ID: " + id);
                    this.reset();

                    this.state = 'sending';
                    this.currentPromptId = id;
                    this.lastSentText = text.trim();
                    this.generationStartTime = Date.now();

                    const success = this.injectAndSend(text);
                    if (!success) {
                        this.finish(id, 'Error: Failed to inject text');
                        return;
                    }

                    this.startCompletionDetection(id);
                } catch (e) {
                    this.log("❌ sendPrompt error: " + e.message);
                    this.finish(id, 'Error: ' + e.message);
                }
            },

            injectAndSend: function(text) {
                const input = document.querySelector('div[contenteditable="true"]');
                if (!input) {
                    this.log("❌ Input box not found");
                    return false;
                }

                const self = this;
                input.focus();
                input.innerText = text;
                input.dispatchEvent(new Event('input', { bubbles: true }));

                setTimeout(() => {
                    self.attemptSend(input, 1);
                }, 400);

                return true;
            },

            attemptSend: function(input, attempt) {
                const self = this;
                const sendBtn = document.querySelector('button[aria-label*="Send"], button[aria-label*="send"]');

                if (sendBtn && !sendBtn.disabled) {
                    sendBtn.click();
                    this.log("👆 Clicked Send Button");
                } else {
                    const enter = new KeyboardEvent('keydown', { bubbles: true, keyCode: 13, key: 'Enter' });
                    input.dispatchEvent(enter);
                }

                this.state = 'generating';
            },

            findUserPromptElement: function(text) {
                const searchPrefix = text.trim().substring(0, 20).toLowerCase();
                const mainEl = document.querySelector('main');
                if (!mainEl) return null;

                const allDivs = mainEl.querySelectorAll('div');
                for (let i = allDivs.length - 1; i >= 0; i--) {
                    const div = allDivs[i];
                    if (div.innerText && div.innerText.toLowerCase().includes(searchPrefix)) {
                        return div;
                    }
                }
                return null;
            },

            getResponseElement: function() {
                if (this.state === 'idle') return null;

                if (!this.userPromptElement) {
                    this.userPromptElement = this.findUserPromptElement(this.lastSentText);
                }

                if (!this.userPromptElement) return null;

                let response = this.userPromptElement.nextElementSibling;
                if (response && response.innerText && response.innerText.trim().length > 0) {
                    return response;
                }

                if (this.userPromptElement.parentElement) {
                    response = this.userPromptElement.parentElement.nextElementSibling;
                    if (response && response.innerText) {
                        return response;
                    }
                }

                return null;
            },

            isGenerating: function() {
                const stopBtn = document.querySelector('button[aria-label*="Stop"]');
                if (stopBtn && stopBtn.offsetParent !== null) return true;

                const sendBtn = document.querySelector('button[aria-label*="Send"]');
                if (sendBtn && sendBtn.disabled) return true;

                return false;
            },

            startCompletionDetection: function(id) {
                const self = this;
                this.inGracePeriod = true;
                this.stopButtonEverSeen = false;

                this.graceTimeout = setTimeout(() => {
                    if (self.state === 'idle') return;
                    self.inGracePeriod = false;
                    self.log("⏱️ Grace period ended");
                }, 2000);

                this.buttonObserver = new MutationObserver(function(mutations) {
                    const stopBtn = document.querySelector('button[aria-label*="Stop"]');
                    if (stopBtn && stopBtn.offsetParent !== null) {
                        self.stopButtonEverSeen = true;
                    }

                    if (self.inGracePeriod) return;

                    if (self.state === 'generating' && self.stopButtonEverSeen && !self.isGenerating()) {
                        setTimeout(() => {
                            if (self.state !== 'generating') return;
                            if (!self.isGenerating()) {
                                self.log("🎯 Completion detected");
                                self.onGenerationComplete(id);
                            }
                        }, 300);
                    }
                });

                this.buttonObserver.observe(document.body, {
                    childList: true,
                    subtree: true,
                    attributes: true
                });
            },

            onGenerationComplete: function(id) {
                if (this.state !== 'generating') return;

                this.state = 'complete';
                this.log("✅ Extracting response...");

                if (this.buttonObserver) {
                    this.buttonObserver.disconnect();
                    this.buttonObserver = null;
                }

                const responseEl = this.getResponseElement();
                let content = '';

                if (responseEl) {
                    content = responseEl.innerText.trim();
                    this.log("📝 Extracted: " + content.length + " chars");
                } else {
                    this.log("⚠️ Could not locate response");
                }

                if (!content || content.length === 0) {
                    this.finish(id, 'Error: Could not extract response');
                } else {
                    this.finish(id, content);
                }
            },

            reset: function() {
                this.state = 'idle';
                this.currentPromptId = null;
                this.userPromptElement = null;
                this.inGracePeriod = false;
                this.stopButtonEverSeen = false;

                if (this.buttonObserver) {
                    this.buttonObserver.disconnect();
                    this.buttonObserver = null;
                }
                if (this.graceTimeout) {
                    clearTimeout(this.graceTimeout);
                    this.graceTimeout = null;
                }
            },

            finish: function(id, content) {
                this.reset();
                this.postToSwift({ type: 'GEMINI_RESPONSE', id: id, content: content || 'Error: No content' });
            },

            forceFinish: function(id) {
                this.log("⚠️ Force finish");
                const responseEl = this.getResponseElement();
                const content = responseEl ? responseEl.innerText.trim() : '';
                this.finish(id, content || 'Error: Timeout');
            },

            checkLogin: function() {
                const loggedIn = window.location.href.includes('gemini.google.com') &&
                                 !!document.querySelector('div[contenteditable="true"]');
                this.postToSwift({ type: 'LOGIN_STATUS', loggedIn: loggedIn });
                return loggedIn;
            }
        };

        setTimeout(function() {
            window.__fetchBridge.checkLogin();
        }, 2000);

        console.log("✅ Dual Bridge v30 Ready");
    })();
    """
}
