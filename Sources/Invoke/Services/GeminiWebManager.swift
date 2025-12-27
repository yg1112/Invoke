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
        
        webView = WKWebView(frame: .zero, configuration: config)
        // 关键：伪装成 Safari，防止被 Google 降级
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        webView.navigationDelegate = self
        loadGemini()
    }
    
    func loadGemini() {
        if let url = URL(string: "https://gemini.google.com/app") {
            webView.load(URLRequest(url: url))
        }
    }
    
    func injectRawCookies(_ cookieText: String, completion: @escaping () -> Void) {
        let js = "document.cookie = '\(cookieText.replacingOccurrences(of: "'", with: "\\'"))';"
        webView.evaluateJavaScript(js) { _, _ in completion() }
    }

    func streamAskGemini(prompt: String, onChunk: @escaping (String) -> Void) async throws -> String {
        guard isReady else { throw NSError(domain: "Gemini", code: 503, userInfo: [NSLocalizedDescriptionKey: "WebView not ready"]) }
        
        return try await withCheckedThrowingContinuation { continuation in
            self.streamCallback = onChunk
            self.streamContinuation = continuation
            
            // 转义 Prompt，防止 JS 注入错误
            let safePrompt = prompt.replacingOccurrences(of: "\\", with: "\\\\")
                                   .replacingOccurrences(of: "\"", with: "\\\"")
                                   .replacingOccurrences(of: "\n", with: "\\n")
                                   .replacingOccurrences(of: "\r", with: "")
            
            let js = "window.__streamingBridge.startGeneration(\"\(safePrompt)\");"
            
            webView.evaluateJavaScript(js) { _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    self.streamCallback = nil; self.streamContinuation = nil
                }
            }
        }
    }
    
    // 🔥 增强版 JS：支持多种选择器，防止找不到元素
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
                // 1. 尝试多种方式找输入框
                const input = document.querySelector('div[contenteditable="true"]') || 
                              document.querySelector('rich-textarea p') ||
                              document.querySelector('textarea');
                              
                if (!input) { this.post('ERROR', 'Input field not found'); return; }
                
                input.focus();
                input.innerText = prompt;
                // 触发事件链，确保 React 识别到输入
                input.dispatchEvent(new InputEvent('input', {bubbles:true, inputType:'insertText'}));
                
                setTimeout(() => {
                    // 2. 尝试多种方式找发送按钮 (包括中文"发送")
                    const sendBtn = document.querySelector('button[aria-label*="Send"]') || 
                                    document.querySelector('button[aria-label*="发送"]') ||
                                    document.querySelector('button.send-button');
                                    
                    if (sendBtn) {
                        sendBtn.click();
                        this.monitorStream();
                    } else {
                        // 尝试回车发送 (Fallback)
                        const enterEvent = new KeyboardEvent('keydown', {
                            bubbles: true, cancelable: true, key: 'Enter', code: 'Enter', keyCode: 13
                        });
                        input.dispatchEvent(enterEvent);
                        this.monitorStream();
                    }
                }, 800);
            },
            
            monitorStream: function() {
                this.lastTextLength = 0;
                let responseEl = null;
                // 轮询直到回复框出现
                let attempts = 0;
                const findTimer = setInterval(() => {
                    attempts++;
                    const allResponses = document.querySelectorAll('.model-response-text'); 
                    if (allResponses.length > 0) {
                        responseEl = allResponses[allResponses.length - 1]; // 取最后一个
                        clearInterval(findTimer);
                        this.attachObserver(responseEl);
                    }
                    if (attempts > 20) { // 10秒超时
                        clearInterval(findTimer);
                        this.post('ERROR', 'Timeout waiting for response bubble');
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
                
                // 轮询检查是否生成结束 (Stop 按钮消失)
                const doneCheck = setInterval(() => {
                    const stopBtn = document.querySelector('button[aria-label*="Stop"]'); // 停止按钮存在说明还在生成
                    // 只有当有内容产生，且停止按钮消失时，才算结束
                    if (!stopBtn && this.lastTextLength > 0) {
                        clearInterval(doneCheck);
                        this.observer.disconnect();
                        this.post('DONE', 'Generation complete');
                    }
                }, 1000);
            }
        };
        
        // 登录状态检测
        setInterval(() => {
            const loggedIn = !!document.querySelector('div[contenteditable="true"]');
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
        case "ERROR": 
            let msg = body["data"] as? String ?? "Unknown JS Error"
            streamContinuation?.resume(throwing: NSError(domain: "JS", code: 500, userInfo: [NSLocalizedDescriptionKey: msg]))
            streamCallback = nil
        case "LOGIN_STATUS":
            let s = body["loggedIn"] as? Bool ?? false
            DispatchQueue.main.async { self.isLoggedIn = s; self.connectionStatus = s ? "🟢 Connected" : "🔴 Need Login" }
        default: break
        }
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { isReady = true }
}