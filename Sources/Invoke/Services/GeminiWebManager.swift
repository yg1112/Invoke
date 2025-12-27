import Foundation
import WebKit
import Combine

@MainActor
class GeminiWebManager: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let shared = GeminiWebManager()
    
    @Published var isReady = false
    @Published var isLoggedIn = false
    @Published var connectionStatus = "Initializing..."
    
    // 隐藏的 WebView，不添加到任何可见窗口
    private(set) var webView: WKWebView!
    private var streamCallback: ((String) -> Void)?
    private var streamContinuation: CheckedContinuation<String, Error>?
    
    override init() {
        super.init()
        setupWebView()
    }
    
    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.applicationNameForUserAgent = "Safari"
        let script = WKUserScript(source: Self.streamingScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(script)
        config.userContentController.add(self, name: "geminiBridge")
        
        // 关键：Frame 设为 zero，不添加到 UI 视图层级中，实现“隐形”
        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        webView.navigationDelegate = self
        loadGemini()
    }
    
    func loadGemini() {
        if let url = URL(string: "https://gemini.google.com/app") { webView.load(URLRequest(url: url)) }
    }
    
    func injectRawCookies(_ cookieText: String, completion: @escaping () -> Void) {
        let js = "document.cookie = '\(cookieText.replacingOccurrences(of: "'", with: "\\'"))';"
        webView.evaluateJavaScript(js) { _, _ in completion() }
    }

    func streamAskGemini(prompt: String, onChunk: @escaping (String) -> Void) async throws -> String {
        guard isReady else { throw NSError(domain: "Gemini", code: 503, userInfo: [NSLocalizedDescriptionKey: "WebView not ready"]) }
        return try await withCheckedThrowingContinuation { continuation in
            self.streamCallback = onChunk; self.streamContinuation = continuation
            
            // 转义 Prompt
            let safePrompt = prompt.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
            let js = "window.__streamingBridge.startGeneration(\"\(safePrompt)\");"
            
            webView.evaluateJavaScript(js) { _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    self.streamCallback = nil; self.streamContinuation = nil
                }
            }
        }
    }
    
    // 🔥 ROBUST JS (Fixes "Waiting..." hang)
    static let streamingScript = """
    (function() {
        window.__streamingBridge = {
            observer: null, lastTextLength: 0,
            post: function(type, data) {
                if (window.webkit && window.webkit.messageHandlers.geminiBridge) {
                    window.webkit.messageHandlers.geminiBridge.postMessage({type: type, data: data});
                }
            },
            startGeneration: function(prompt) {
                const input = document.querySelector('div[contenteditable="true"]') || document.querySelector('rich-textarea p');
                if (!input) { this.post('ERROR', 'Input not found'); return; }
                
                input.focus();
                input.innerText = prompt;
                input.dispatchEvent(new InputEvent('input', {bubbles:true, inputType:'insertText'}));
                
                setTimeout(() => {
                    const sendBtn = document.querySelector('button[aria-label*="Send"]') || document.querySelector('button[aria-label*="发送"]');
                    if (sendBtn) {
                        sendBtn.click();
                        this.monitorStream();
                    } else {
                        // 尝试回车兜底
                        input.dispatchEvent(new KeyboardEvent('keydown', {bubbles:true, key:'Enter', code:'Enter', keyCode:13}));
                        this.monitorStream();
                    }
                }, 800); // 增加延时确保 UI 响应
            },
            monitorStream: function() {
                this.lastTextLength = 0;
                const findTimer = setInterval(() => {
                    const allResponses = document.querySelectorAll('.model-response-text'); 
                    if (allResponses.length > 0) {
                        clearInterval(findTimer);
                        this.attachObserver(allResponses[allResponses.length - 1]);
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