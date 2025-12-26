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

/// Native Gemini Bridge - v17.0 (DEBUG MODE)
/// 目标：可视化调试 + 详细埋点日志
@MainActor
class GeminiWebManager: NSObject, ObservableObject {
    static let shared = GeminiWebManager()
    
    // MARK: - Published State
    @Published var isReady = false
    @Published var isLoggedIn = false
    @Published var isProcessing = false
    @Published var connectionStatus = "Initializing..."
    @Published var lastResponse: String = ""
    
    // MARK: - Internal
    private(set) var webView: WKWebView!
    private var debugWindow: NSWindow? // 改名为 debugWindow 以明确用途
    private var responseCallback: ((String) -> Void)?
    
    private struct PendingRequest {
        let prompt: String
        let model: String
        let continuation: CheckedContinuation<String, Error>
    }
    
    private var requestStream: AsyncStream<PendingRequest>.Continuation?
    private var requestTask: Task<Void, Never>?
    
    public static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
    
    override init() {
        super.init()
        setupWebView()
        startRequestLoop()
    }
    
    deinit {
        requestTask?.cancel()
        debugWindow?.close()
    }

    // MARK: - Queue Management
    
    private func startRequestLoop() {
        let (stream, continuation) = AsyncStream<PendingRequest>.makeStream()
        self.requestStream = continuation
        
        self.requestTask = Task {
            for await request in stream {
                if !self.isReady {
                    print("⚠️ [Queue] WebView not ready, waiting...")
                    try? await Task.sleep(nanoseconds: 2 * 1_000_000_000)
                }
                
                print("🚀 [Queue] Processing Request: \(request.prompt.prefix(20))...")
                
                do {
                    let response = try await self.performActualNetworkRequest(request.prompt, model: request.model)
                    request.continuation.resume(returning: response)
                } catch {
                    print("❌ [Queue] Request failed: \(error)")
                    if let err = error as? GeminiError, case .timeout = err {
                         await self.reloadPageAsync()
                    }
                    request.continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Setup
    
    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.applicationNameForUserAgent = "Safari"
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        
        // 注入功能脚本
        let userScript = WKUserScript(source: Self.injectedScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(userScript)
        
        let fingerprintScript = WKUserScript(source: Self.fingerprintMaskScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        config.userContentController.addUserScript(fingerprintScript)
        
        config.userContentController.add(self, name: "geminiBridge")
        
        // WebView 初始化
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800), configuration: config)
        webView.customUserAgent = Self.userAgent
        webView.navigationDelegate = self
        
        // 🚨 DEBUG 模式：强制显示窗口在屏幕中央
        debugWindow = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1200, height: 800), // 屏幕可见区域
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        debugWindow?.title = "Fetch Debugger - Gemini View"
        debugWindow?.contentView = webView
        debugWindow?.makeKeyAndOrderFront(nil) // 强制前台显示
        debugWindow?.level = .floating // 浮在最上层，方便你看
        
        restoreCookiesFromStorage { [weak self] in
            self?.loadGemini()
        }
    }
    
    func loadGemini() {
        if let url = URL(string: "https://gemini.google.com/app") {
            webView.load(URLRequest(url: url))
        }
    }
    
    private func reloadPageAsync() async {
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                self.reloadPage()
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { continuation.resume() }
            }
        }
    }
    
    // MARK: - Async / Await API
    
    func askGemini(prompt: String, model: String = "default") async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let req = PendingRequest(prompt: prompt, model: model, continuation: continuation)
            if let stream = self.requestStream {
                stream.yield(req)
            } else {
                continuation.resume(throwing: GeminiError.systemError("Stream not ready"))
            }
        }
    }
    
    // MARK: - Internal Execution
    
    private func performActualNetworkRequest(_ text: String, model: String) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                self.isProcessing = true
                let promptId = UUID().uuidString
                
                self.responseCallback = { response in
                    self.isProcessing = false
                    print("📥 [Swift] Received Response Length: \(response.count)")
                    if response.hasPrefix("Error:") {
                        continuation.resume(throwing: GeminiError.responseError(response))
                    } else {
                        continuation.resume(returning: response)
                    }
                }
                
                let escapedText = text.replacingOccurrences(of: "\\", with: "\\\\")
                                      .replacingOccurrences(of: "\"", with: "\\\"")
                                      .replacingOccurrences(of: "\n", with: "\\n")
                
                print("📤 [Swift] Sending Prompt to JS...")
                let js = "window.__fetchBridge.sendPrompt(\"\(escapedText)\", \"\(promptId)\");"
                
                self.webView.evaluateJavaScript(js) { result, error in
                    if let error = error {
                        print("❌ [Swift] JS Eval Error: \(error)")
                        self.handleError("JS Error: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
    
    private func handleError(_ msg: String) {
        DispatchQueue.main.async { [weak self] in
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
    
    // MARK: - Cookie / Persistence (Standard)
    private static let cookieStorageKey = "FetchGeminiCookies"
    
    func injectRawCookies(_ cookieString: String, completion: @escaping () -> Void) {
        let dataStore = WKWebsiteDataStore.default()
        let cookieStore = dataStore.httpCookieStore
        let components = cookieString.components(separatedBy: ";")
        
        let group = DispatchGroup()
        var cookiesToSave: [[String: Any]] = []
        
        for component in components {
            let parts = component.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                let name = parts[0].trimmingCharacters(in: .whitespaces)
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                let properties: [HTTPCookiePropertyKey: Any] = [
                    .domain: ".google.com", .path: "/", .name: name, .value: value, .secure: "TRUE",
                    .expires: Date(timeIntervalSinceNow: 31536000)
                ]
                
                if let cookie = HTTPCookie(properties: properties) {
                    group.enter()
                    cookieStore.setCookie(cookie) { group.leave() }
                    cookiesToSave.append([
                        "name": name, "value": value, "domain": ".google.com", "path": "/",
                        "expires": Date(timeIntervalSinceNow: 31536000).timeIntervalSince1970
                    ])
                }
            }
        }
        
        group.notify(queue: .main) { [weak self] in
            UserDefaults.standard.set(cookiesToSave, forKey: Self.cookieStorageKey)
            self?.reloadPage()
            completion()
        }
    }
    
    func restoreCookiesFromStorage(completion: @escaping () -> Void) {
        guard let savedCookies = UserDefaults.standard.array(forKey: Self.cookieStorageKey) as? [[String: Any]] else {
            completion(); return
        }
        let cookieStore = WKWebsiteDataStore.default().httpCookieStore
        let group = DispatchGroup()
        for cookieData in savedCookies {
            guard let name = cookieData["name"] as? String,
                  let value = cookieData["value"] as? String,
                  let domain = cookieData["domain"] as? String,
                  let path = cookieData["path"] as? String else { continue }
            let props: [HTTPCookiePropertyKey: Any] = [.domain: domain, .path: path, .name: name, .value: value, .secure: "TRUE"]
            if let cookie = HTTPCookie(properties: props) {
                group.enter(); cookieStore.setCookie(cookie) { group.leave() }
            }
        }
        group.notify(queue: .main) { completion() }
    }
    
    func reloadPage() {
        if let url = URL(string: "https://gemini.google.com/app") { webView.load(URLRequest(url: url)) }
    }
    
    func clearCookies(completion: @escaping () -> Void) {
        let dataStore = WKWebsiteDataStore.default()
        dataStore.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            let googleRecords = records.filter { $0.displayName.contains("google") }
            dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: googleRecords, completionHandler: completion)
        }
    }
    
    func checkLoginStatus() {
        let js = "window.__fetchBridge ? window.__fetchBridge.checkLogin() : false;"
        webView.evaluateJavaScript(js) { [weak self] result, error in
            DispatchQueue.main.async {
                if let loggedIn = result as? Bool {
                    self?.isLoggedIn = loggedIn
                    self?.connectionStatus = loggedIn ? "🟢 Connected" : "🔴 Need Login"
                    print("🔍 [Login Check] Status: \(loggedIn)")
                }
            }
        }
    }
}

// MARK: - Delegates

extension GeminiWebManager: WKNavigationDelegate, WKScriptMessageHandler {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("✅ [WebView] Load Finished")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.isReady = true
            self?.checkLoginStatus()
        }
    }
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "geminiBridge", let body = message.body as? [String: Any] else { return }
        
        let type = body["type"] as? String ?? ""
        
        switch type {
        case "LOG":
            // 📝 JS 传回来的日志
            let msg = body["message"] as? String ?? ""
            print("🖥️ [JS-Log] \(msg)")
            
        case "GEMINI_RESPONSE":
            let content = body["content"] as? String ?? ""
            let id = body["id"] as? String ?? "unknown"
            print("📬 [Bridge] Response Received for ID: \(id), Length: \(content.count)")
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if let callback = self.responseCallback {
                    self.lastResponse = content
                    if content.isEmpty { callback("Error: Empty response") } 
                    else { callback(content) }
                    self.responseCallback = nil
                }
                if !content.isEmpty && !content.hasPrefix("Error:") {
                    GeminiLinkLogic.shared.processResponse(content)
                }
            }
            
        case "LOGIN_STATUS":
            let loggedIn = body["loggedIn"] as? Bool ?? false
            DispatchQueue.main.async { [weak self] in
                self?.isLoggedIn = loggedIn
                self?.connectionStatus = loggedIn ? "🟢 Connected" : "🔴 Need Login"
            }
            
        default: break
        }
    }
}

// MARK: - Injected Scripts (Debug Version)

extension GeminiWebManager {
    static let fingerprintMaskScript = """
    (function() {
        if (navigator.webdriver) { delete navigator.webdriver; }
        Object.defineProperty(navigator, 'webdriver', { get: () => undefined, configurable: true });
    })();
    """
    
    // 🔍 埋点重点：每一个关键步骤都通过 postToSwift({type: 'LOG'}) 传回来
    static let injectedScript = """
    (function() {
        console.log("🚀 Bridge v17 (DEBUG) Initializing...");
        
        window.__fetchBridge = {
            log: function(msg) {
                console.log("[Bridge] " + msg);
                this.postToSwift({ type: 'LOG', message: msg });
            },

            sendPrompt: function(text, id) {
                this.log("Step 1: sendPrompt called. Text length: " + text.length);
                this.lastSentText = text.trim();
                
                const input = document.querySelector('div[contenteditable="true"]');
                if (!input) {
                    this.log("❌ Error: Input box not found.");
                    this.postToSwift({ type: 'GEMINI_RESPONSE', id: id, content: "Error: Input box not found." });
                    return;
                }
                
                this.log("Step 2: Found input box. Inserting text...");
                input.focus();
                document.execCommand('selectAll', false, null);
                document.execCommand('delete', false, null);
                document.execCommand('insertText', false, text);
                
                setTimeout(() => {
                    const sendBtn = document.querySelector('button[aria-label*="Send"], button[class*="send-button"]');
                    if (sendBtn) {
                        this.log("Step 3: Clicked Send Button");
                        sendBtn.click();
                        this.waitForResponse(id);
                    } else {
                        this.log("Step 3: Send Button NOT found, trying Enter key");
                        const enter = new KeyboardEvent('keydown', { bubbles: true, cancelable: true, keyCode: 13, key: 'Enter' });
                        input.dispatchEvent(enter);
                        this.waitForResponse(id);
                    }
                }, 500);
            },
            
            waitForResponse: function(id) {
                this.log("Step 4: Waiting for response (MutationObserver started)");
                const self = this;
                let hasStarted = false;
                let silenceTimer = null;
                const startTime = Date.now();
                
                // 复读机检测逻辑
                const isNoise = (text, elementDescription) => {
                    if (!text) return true;
                    const t = text.trim();
                    
                    // Log检测过程
                    // self.log("Checking candidate: " + t.substring(0, 20) + "...");
                    
                    if (self.lastSentText && t === self.lastSentText) {
                        self.log("⚠️ IGNORED: Exact match with sent text (Echo detected) in " + elementDescription);
                        return true;
                    }
                    if (t.toLowerCase().includes('sign in') && t.toLowerCase().includes('google account')) return true;
                    if (t.length < 5) return true;
                    return false;
                };
                
                const observer = new MutationObserver((mutations) => {
                    // 仅当出现 Stop 按钮时才认为回复开始生成了
                    const stopBtn = document.querySelector('button[aria-label*="Stop"], button[aria-label*="停止"]');
                    
                    if (stopBtn) {
                        if (!hasStarted) self.log("🌊 Stream started (Stop button appeared)");
                        hasStarted = true;
                        if (silenceTimer) { clearTimeout(silenceTimer); silenceTimer = null; }
                    } else if (hasStarted) {
                        // Stop 按钮消失，说明可能生成完毕，等待静默时间
                        if (!silenceTimer) {
                            self.log("⏳ Stream ended (Stop button gone), waiting for silence...");
                            silenceTimer = setTimeout(() => finish('silence'), 2000); 
                        }
                    } else if (Date.now() - startTime > 45000) {
                        finish('timeout');
                    }
                });
                
                const finish = (reason) => {
                    self.log("Step 5: Finishing... Reason: " + reason);
                    observer.disconnect();
                    let text = "";
                    
                    // 调试：打印当前页面可能的回复容器
                    const selectors = [
                        '.model-response', 
                        'div[data-message-author-role="model"]', 
                        '.message-content' // 这是一个通用类，容易误判，放在最后
                    ];
                    
                    for (const sel of selectors) {
                        const els = document.querySelectorAll(sel);
                        self.log(`🔍 Scanning selector: '${sel}', Found: ${els.length} elements`);
                        
                        for (let i = els.length - 1; i >= 0; i--) {
                            const candidate = els[i].innerText;
                            const classNames = els[i].className;
                            
                            if (!isNoise(candidate, sel + " (" + classNames + ")")) {
                                text = candidate;
                                self.log("✅ Match found in: " + sel);
                                break;
                            }
                        }
                        if (text) break;
                    }
                    
                    if (!text) self.log("❌ No valid response found after scan.");
                    
                    text = (text || "").replace(/^\\s*Show thinking\\s*/gi, '').trim();
                    
                    self.postToSwift({ type: 'GEMINI_RESPONSE', id: id, content: text });
                };
                
                observer.observe(document.body, { childList: true, subtree: true, characterData: true });
                
                setTimeout(() => { 
                    observer.disconnect(); 
                    if (!hasStarted) {
                        self.log("❌ Timeout: Stream never started.");
                        finish('timeout');
                    }
                }, 46000);
            },
            
            checkLogin: function() {
                const loggedIn = window.location.href.includes('gemini.google.com') && 
                                 !!document.querySelector('div[contenteditable="true"]');
                this.postToSwift({ type: 'LOGIN_STATUS', loggedIn: loggedIn });
                return loggedIn;
            },
            
            postToSwift: function(data) {
                if (window.webkit && window.webkit.messageHandlers.geminiBridge) {
                    window.webkit.messageHandlers.geminiBridge.postMessage(data);
                }
            }
        };
        
        setTimeout(() => window.__fetchBridge.checkLogin(), 2000);
    })();
    """
}
