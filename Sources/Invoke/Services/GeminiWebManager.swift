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

/// Native Gemini Bridge - v22.0 (Strict Selector & Anti-Ghost)
/// 修复核心：
/// 1. 移除 .message-content Fallback，杜绝抓取到用户气泡（解决"重复回复"）。
/// 2. 优化重试逻辑，防止"第三个你好"。
/// 3. 增加对 Aider 内部指令的静默处理。
@MainActor
class GeminiWebManager: NSObject, ObservableObject {
    static let shared = GeminiWebManager()
    
    @Published var isReady = false
    @Published var isLoggedIn = false
    @Published var isProcessing = false
    @Published var connectionStatus = "Initializing..."
    @Published var lastResponse: String = ""
    
    private(set) var webView: WKWebView!
    private var debugWindow: NSWindow?
    private var responseCallback: ((String) -> Void)?
    
    private struct PendingRequest {
        let prompt: String
        let model: String
        let continuation: CheckedContinuation<String, Error>
    }
    
    private var requestStream: AsyncStream<PendingRequest>.Continuation?
    private var requestTask: Task<Void, Never>?
    private var watchdogTimer: Timer?
    
    public static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
    
    override init() {
        super.init()
        setupWebView()
        startRequestLoop()
    }
    
    deinit {
        requestTask?.cancel()
        debugWindow?.close()
        watchdogTimer?.invalidate()
    }

    private func startRequestLoop() {
        let (stream, continuation) = AsyncStream<PendingRequest>.makeStream()
        self.requestStream = continuation
        
        self.requestTask = Task {
            for await request in stream {
                if !self.isReady { try? await Task.sleep(nanoseconds: 2 * 1_000_000_000) }
                
                print("🚀 [Queue] Processing: \(request.prompt.prefix(15))...")
                
                do {
                    let response = try await self.performActualNetworkRequest(request.prompt, model: request.model)
                    request.continuation.resume(returning: response)
                } catch {
                    print("❌ [Queue] Failed: \(error)")
                    if let err = error as? GeminiError, case .timeout = err { await self.reloadPageAsync() }
                    request.continuation.resume(throwing: error)
                }
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
        
        // 🚨 保持调试窗口开启，方便你确认"幽灵消息"
        debugWindow = NSWindow(
            contentRect: NSRect(x: 50, y: 50, width: 1100, height: 850),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        debugWindow?.title = "Fetch Debugger (v22 Strict)"
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { continuation.resume() }
            }
        }
    }
    
    func askGemini(prompt: String, model: String = "default") async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let req = PendingRequest(prompt: prompt, model: model, continuation: continuation)
            if let stream = self.requestStream { stream.yield(req) } 
            else { continuation.resume(throwing: GeminiError.systemError("Stream Error")) }
        }
    }
    
    private func performActualNetworkRequest(_ text: String, model: String) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                self.isProcessing = true
                let promptId = UUID().uuidString
                
                self.watchdogTimer?.invalidate()
                self.responseCallback = nil
                
                self.responseCallback = { response in
                    self.watchdogTimer?.invalidate()
                    self.isProcessing = false
                    
                    if response.hasPrefix("Error:") { 
                        continuation.resume(throwing: GeminiError.responseError(response)) 
                    } else { 
                        continuation.resume(returning: response) 
                    }
                }
                
                // 延长超时到 50s，因为 Aider 可能会先发一条幽灵消息
                self.watchdogTimer = Timer.scheduledTimer(withTimeInterval: 50.0, repeats: false) { [weak self] _ in
                    print("⏰ Timeout. Force scrape...")
                    self?.forceScrape(id: promptId)
                }
                
                let escapedText = text.replacingOccurrences(of: "\\", with: "\\\\")
                                      .replacingOccurrences(of: "\"", with: "\\\"")
                                      .replacingOccurrences(of: "\n", with: "\\n")
                
                let js = "window.__fetchBridge.sendPromptStrict(\"\(escapedText)\", \"\(promptId)\");"
                self.webView.evaluateJavaScript(js) { _, _ in }
            }
        }
    }
    
    private func forceScrape(id: String) {
        let js = "window.__fetchBridge.forceFinish('\(id)');"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
    
    private func handleError(_ msg: String) {
        DispatchQueue.main.async { [weak self] in
            self?.watchdogTimer?.invalidate()
            self?.isProcessing = false
            self?.responseCallback?(msg)
            self?.responseCallback = nil
        }
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
    func injectRawCookies(_ c: String, completion: @escaping () -> Void) { /* ... */ }
    
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.isReady = true; self?.checkLoginStatus() }
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
                    
                    if !content.isEmpty && !content.hasPrefix("Error:") { 
                        GeminiLinkLogic.shared.processResponse(content) 
                    }
                }
            }
        case "LOGIN_STATUS":
            let loggedIn = body["loggedIn"] as? Bool ?? false
            DispatchQueue.main.async { [weak self] in self?.isLoggedIn = loggedIn; self?.connectionStatus = loggedIn ? "🟢 Connected" : "🔴 Need Login" }
        default: break
        }
    }
}

// MARK: - Injected Scripts (V22 - The Silencer)
extension GeminiWebManager {
    static let fingerprintMaskScript = """
    (function() {
        if (navigator.webdriver) { delete navigator.webdriver; }
        Object.defineProperty(navigator, 'webdriver', { get: () => undefined, configurable: true });
    })();
    """
    
    static let injectedScript = """
    (function() {
        console.log("🚀 Bridge v22 (Strict) Initializing...");
        
        window.__fetchBridge = {
            log: function(msg) { this.postToSwift({ type: 'LOG', message: msg }); },

            sendPromptStrict: function(text, id) {
                this.log("Step 1: Sending... " + text.substring(0, 10));
                this.lastSentText = text.trim();
                
                // 严格模式：只数 role="model" 的气泡
                this.initialModelCount = document.querySelectorAll('div[data-message-author-role="model"]').length;
                
                const input = document.querySelector('div[contenteditable="true"]');
                if (!input) {
                    this.log("❌ Input missing");
                    this.postToSwift({ type: 'GEMINI_RESPONSE', id: id, content: "Error: Input box not found." });
                    return;
                }
                
                // 1. 写入 (Deep Write)
                input.focus();
                document.execCommand('selectAll', false, null);
                document.execCommand('delete', false, null);
                input.innerText = text; // 暴力写入
                input.dispatchEvent(new Event('input', { bubbles: true }));
                
                // 2. 点击发送 (不重试，防止发两条)
                setTimeout(() => {
                    const sendBtn = document.querySelector('button[aria-label*="Send"], button[class*="send-button"]');
                    if (sendBtn) {
                        sendBtn.click();
                        this.log("👆 Clicked Send");
                    } else {
                        const enter = new KeyboardEvent('keydown', { bubbles: true, cancelable: true, keyCode: 13, key: 'Enter' });
                        input.dispatchEvent(enter);
                        this.log("⌨️ Hit Enter");
                    }
                    this.startPolling(id);
                }, 600);
            },
            
            startPolling: function(id) {
                const self = this;
                if (this.pollingTimer) clearInterval(this.pollingTimer);
                this.log("Step 2: Polling for new Model bubble...");
                
                let stableCount = 0;
                let lastTextLen = 0;
                const startTime = Date.now();
                
                this.pollingTimer = setInterval(() => {
                    if (Date.now() - startTime > 48000) {
                        self.finish(id, "timeout");
                        return;
                    }
                    
                    const modelBubbles = document.querySelectorAll('div[data-message-author-role="model"]');
                    const currentCount = modelBubbles.length;
                    
                    // 只有当 AI 气泡数量增加时，才认为是回复
                    if (currentCount > self.initialModelCount) {
                        const lastBubble = modelBubbles[currentCount - 1];
                        const text = lastBubble.innerText.trim();
                        
                        // 垃圾过滤 (Anti-Ghost)
                        if (text.length < 1) return;
                        if (text === "Thinking...") return; // 忽略 Thinking 状态
                        
                        // 稳定性检查
                        if (text.length === lastTextLen) {
                            stableCount++;
                            if (stableCount > 3) { // 1.5s 稳定
                                self.finish(id, "completed");
                            }
                        } else {
                            stableCount = 0;
                            lastTextLen = text.length;
                        }
                    }
                }, 500);
            },
            
            finish: function(id, reason) {
                if (this.pollingTimer) { clearInterval(this.pollingTimer); this.pollingTimer = null; }
                this.log("Step 3: Finishing via " + reason);
                
                const text = this.extractStrict();
                this.postToSwift({ type: 'GEMINI_RESPONSE', id: id, content: text });
            },
            
            forceFinish: function(id) {
                this.finish(id, "force_scrape");
            },
            
            extractStrict: function() {
                // 严禁 Fallback！只抓取 role="model"
                const modelBubbles = document.querySelectorAll('div[data-message-author-role="model"]');
                if (modelBubbles.length === 0) return "Error: No model response found (Strict Mode)";
                
                // 返回最后一个
                const t = modelBubbles[modelBubbles.length - 1].innerText.trim();
                
                // 再次检查是不是把用户的话当成 Model 了 (防止 Google DOM 变动导致 role 错乱)
                if (this.lastSentText && t === this.lastSentText) {
                    return "Error: Echo detected (Scraper grabbed user text)";
                }
                
                return t;
            },
            
            checkLogin: function() {
                const loggedIn = window.location.href.includes('gemini.google.com') && !!document.querySelector('div[contenteditable="true"]');
                this.postToSwift({ type: 'LOGIN_STATUS', loggedIn: loggedIn });
                return loggedIn;
            },
            postToSwift: function(data) { if (window.webkit) window.webkit.messageHandlers.geminiBridge.postMessage(data); }
        };
        setTimeout(() => window.__fetchBridge.checkLogin(), 2000);
    })();
    """
}
