import Foundation
import WebKit
import Combine

@MainActor
class GeminiWebManager: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let shared = GeminiWebManager()
    
    @Published var isReady = false
    @Published var isLoggedIn = false
    @Published var connectionStatus = "Initializing..."
    
    private(set) var webView: WKWebView!
    private var debugWindow: NSWindow?
    private var streamCallback: ((String) -> Void)?
    private var streamContinuation: CheckedContinuation<String, Error>?
    
    // 静态属性
    static let fingerprintMaskScript = """
    // Minimal fingerprint masking
    Object.defineProperty(navigator, 'webdriver', {get: () => undefined});
    """

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
    
    override init() {
        super.init()
        setupWebView()
    }
    
    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.applicationNameForUserAgent = "Safari"
        // 注入 v30 流式脚本
        let script = WKUserScript(source: Self.streamingScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(script)
        config.userContentController.add(self, name: "geminiBridge")
        
        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        webView.navigationDelegate = self
        
        loadGemini()
    }
    
    func loadGemini() {
        if let url = URL(string: "https://gemini.google.com/app") {
            webView.load(URLRequest(url: url))
        }
    }

    // 真·流式调用
    func streamAskGemini(prompt: String, onChunk: @escaping (String) -> Void) async throws -> String {
        guard isReady else { throw NSError(domain: "Gemini", code: 503, userInfo: [NSLocalizedDescriptionKey: "WebView not ready"]) }
        
        return try await withCheckedThrowingContinuation { continuation in
            self.streamCallback = onChunk
            self.streamContinuation = continuation
            
            let safePrompt = prompt.replacingOccurrences(of: "\\", with: "\\\\")
                                   .replacingOccurrences(of: "\"", with: "\\\"")
                                   .replacingOccurrences(of: "\n", with: "\\n")
            
            let js = "window.__streamingBridge.startGeneration(\"\(safePrompt)\");"
            
            webView.evaluateJavaScript(js) { _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    self.streamCallback = nil; self.streamContinuation = nil
                }
            }
        }
    }
    
    // 添加缺失的方法
    func injectRawCookies(_ cookieText: String, completion: @escaping () -> Void) {
        // 简单的cookie注入，假设cookieText是JSON或字符串
        let js = "document.cookie = '\(cookieText.replacingOccurrences(of: "'", with: "\\'"))';"
        webView.evaluateJavaScript(js) { _, _ in
            completion()
        }
    }
    
    func checkLoginStatus() {
        // 触发登录检查，通过JS
        let js = "window.__streamingBridge.post('LOGIN_STATUS', {loggedIn: !!document.querySelector('div[contenteditable=\"true\"]')});"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
    
    // v30 JS 核心：MutationObserver + CHUNK
    static let streamingScript = """
    (function() {
        window.__streamingBridge = {
            observer: null,
            lastTextLength: 0,
            
            post: function(type, data) {
                if (window.webkit && window.webkit.messageHandlers.geminiBridge) {
                    window.webkit.messageHandlers.geminiBridge.postMessage({type: type, data: data});
                }
            },
            
            startGeneration: function(prompt) {
                // 增加 fallback，防止 Google 改 class 名
                const input = document.querySelector('div[contenteditable="true"]') || 
                              document.querySelector('rich-textarea p') ||
                              document.querySelector('textarea');
                              
                if (!input) { this.post('ERROR', 'Input not found'); return; }
                
                input.focus();
                input.innerText = prompt;
                // 模拟更真实的用户输入事件，触发 React/Angular 的绑定
                input.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText' }));
                
                setTimeout(() => {
                    const sendBtn = document.querySelector('button[aria-label*="Send"]') || 
                                    document.querySelector('button[aria-label*="发送"]') ||
                                    document.querySelector('button.send-button'); // 假设的兜底
                    if (sendBtn) {
                        sendBtn.click();
                        this.monitorStream();
                    } else {
                        this.post('ERROR', 'Send button not found');
                    }
                }, 600); // 稍微加长一点等待时间
            },
            
            monitorStream: function() {
                this.lastTextLength = 0;
                let responseEl = null;
                const findTimer = setInterval(() => {
                    const allResponses = document.querySelectorAll('.model-response-text'); 
                    if (allResponses.length > 0) {
                        responseEl = allResponses[allResponses.length - 1];
                        if (responseEl) {
                            clearInterval(findTimer);
                            this.attachObserver(responseEl);
                        }
                    }
                }, 500);
            },
            
            attachObserver: function(target) {
                if (this.observer) this.observer.disconnect();
                this.observer = new MutationObserver(() => {
                    const fullText = target.innerText || "";
                    const newPart = fullText.substring(this.lastTextLength);
                    if (newPart.length > 0) {
                        this.post('CHUNK', newPart);
                        this.lastTextLength = fullText.length;
                    }
                });
                this.observer.observe(target, {childList: true, subtree: true, characterData: true});
                
                const doneCheck = setInterval(() => {
                    const stopBtn = document.querySelector('button[aria-label*=\"Stop\"]');
                    if (!stopBtn && this.lastTextLength > 0) {
                        clearInterval(doneCheck);
                        this.observer.disconnect();
                        this.post('DONE', 'Generation complete');
                    }
                }, 1000);
            }
        };
        // Login Checker
        setInterval(() => {
            const loggedIn = !!document.querySelector('div[contenteditable=\"true\"]');
            if (window.webkit && window.webkit.messageHandlers.geminiBridge) {
                window.webkit.messageHandlers.geminiBridge.postMessage({type: 'LOGIN_STATUS', loggedIn: loggedIn});
            }
        }, 3000);
    })();
    """
    
    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "CHUNK": if let text = body["data"] as? String { streamCallback?(text) }
        case "DONE": streamContinuation?.resume(returning: "Done"); streamCallback = nil; streamContinuation = nil
        case "ERROR": streamContinuation?.resume(throwing: NSError(domain: "JS", code: 500)); streamCallback = nil
        case "LOGIN_STATUS":
            let s = body["loggedIn"] as? Bool ?? false
            DispatchQueue.main.async { self.isLoggedIn = s; self.connectionStatus = s ? "🟢 Connected" : "🔴 Need Login" }
        default: break
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { isReady = true }
}