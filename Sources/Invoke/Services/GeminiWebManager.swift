import Foundation
import WebKit
import Combine
import AppKit

// MARK: - InteractiveWebView 子类
/// 解决 WKWebView 在 SwiftUI 中无法接收键盘输入的问题
class InteractiveWebView: WKWebView {
    // 核心修复：明确告诉系统这个 View 接受第一响应者状态
    override var acceptsFirstResponder: Bool {
        return true
    }
    
    // 处理鼠标点击事件，确保点击即聚焦
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        self.window?.makeFirstResponder(self)
    }
    
    // 确保键盘事件被正确处理
    override func keyDown(with event: NSEvent) {
        super.keyDown(with: event)
    }
    
    override func becomeFirstResponder() -> Bool {
        return true
    }
}

/// Native Gemini Bridge - 替代 Chrome Extension + proxy.py
/// 使用 WKWebView 直接与 gemini.google.com 通信
class GeminiWebManager: NSObject, ObservableObject {
    static let shared = GeminiWebManager()
    
    // MARK: - Published State
    @Published var isReady = false
    @Published var isLoggedIn = false
    @Published var isProcessing = false
    @Published var connectionStatus = "Initializing..."
    @Published var lastResponse: String = ""
    
    // MARK: - WebView
    private(set) var webView: WKWebView!
    private var pendingPromptId: String?
    private var responseCallback: ((String) -> Void)?
    
    // 使用最新的 macOS Safari UA (保持更新)
    // 移除 "Version/17.2" 这种可能过时的标记，使用通用格式
    public static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
    
    override init() {
        super.init()
        setupWebView()
    }
    
    // MARK: - Setup
    
    private func setupWebView() {
        let config = WKWebViewConfiguration()
        
        // 持久化 Cookie (登录态)
        config.websiteDataStore = WKWebsiteDataStore.default()
        
        // 明确告诉服务器我是 Safari
        config.applicationNameForUserAgent = "Safari"
        
        // 启用开发者工具 (有时能绕过简单检查)
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        
        // 允许 JavaScript
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        
        // 注入脚本 (包含浏览器特征伪装)
        let userScript = WKUserScript(
            source: Self.injectedScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(userScript)
        
        // 注入浏览器指纹伪装脚本 (在 document start 时执行)
        let fingerprintScript = WKUserScript(
            source: Self.fingerprintMaskScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(fingerprintScript)
        
        // Swift <-> JS 消息通道
        config.userContentController.add(self, name: "geminiBridge")
        
        // 创建可交互的 WebView (使用子类以支持键盘输入)
        webView = InteractiveWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        webView.customUserAgent = Self.userAgent
        webView.navigationDelegate = self
        
        // 允许检查元素 (调试用)
        #if DEBUG
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        #endif
        
        // 先恢复持久化的 Cookie，再加载 Gemini
        restoreCookiesFromStorage { [weak self] in
            self?.loadGemini()
        }
    }
    
    func loadGemini() {
        connectionStatus = "Loading Gemini..."
        if let url = URL(string: "https://gemini.google.com/app") {
            webView.load(URLRequest(url: url))
        }
    }
    
    // MARK: - Public API
    
    /// 发送 Prompt 给 Gemini，异步返回响应
    func sendPrompt(_ text: String, model: String = "default", completion: @escaping (String) -> Void) {
        guard isReady && isLoggedIn else {
            completion("Error: Gemini not ready or not logged in")
            return
        }
        
        isProcessing = true
        pendingPromptId = UUID().uuidString
        responseCallback = completion
        
        // 先执行清理脚本，关闭干扰弹窗
        let cleanupScript = """
        (function() {
            // 1. 尝试点击 "Close", "No thanks", "Maybe later" 等按钮
            const buttons = Array.from(document.querySelectorAll('button'));
            const dismissBtns = buttons.filter(b => {
                const text = b.innerText || '';
                const ariaLabel = b.getAttribute('aria-label') || '';
                return text.match(/Close|No thanks|Maybe later|Got it|Dismiss/i) || 
                       ariaLabel.match(/Close|Dismiss/i);
            });
            dismissBtns.forEach(b => {
                try { b.click(); } catch(e) {}
            });
            
            // 2. 返回当前状态诊断
            return {
                url: window.location.href,
                hasInput: !!(document.querySelector('div[contenteditable="true"]') || 
                            document.querySelector('rich-textarea') ||
                            document.querySelector('div[role="textbox"]')),
                bodyLength: document.body ? document.body.innerText.length : 0,
                htmlPreview: document.body ? document.body.innerHTML.substring(0, 500) : ''
            };
        })();
        """
        
        webView.evaluateJavaScript(cleanupScript) { [weak self] result, error in
            guard let self = self else { return }
            
            if let error = error {
                print("⚠️ Cleanup script error: \(error.localizedDescription)")
            } else if let diagnostic = result as? [String: Any] {
                print("🔍 Page diagnostic: URL=\(diagnostic["url"] ?? "unknown"), hasInput=\(diagnostic["hasInput"] ?? false)")
                if let htmlPreview = diagnostic["htmlPreview"] as? String, !htmlPreview.isEmpty {
                    print("📄 HTML preview (first 500 chars): \(htmlPreview)")
                }
            }
            
            // 继续发送 prompt
            let escapedText = text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "")
            
            let js = """
            window.__fetchBridge.sendPrompt("\(escapedText)", "\(model)", "\(self.pendingPromptId!)");
            """
            
            self.webView.evaluateJavaScript(js) { _, error in
                if let error = error {
                    print("❌ JS Error: \(error)")
                    self.isProcessing = false
                    completion("Error: \(error.localizedDescription)")
                }
            }
        }
    }
    
    // MARK: - Async API (for LocalAPIServer)
    
    /// 异步问答接口 - 供 LocalAPIServer 调用
    func askGemini(prompt: String, model: String = "default") async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            guard self.isReady && self.isLoggedIn else {
                // 增加调试日志
                print("❌ askGemini failed: isReady=\(self.isReady), isLoggedIn=\(self.isLoggedIn)")
                
                // 获取页面 HTML 摘要用于调试
                DispatchQueue.main.async { [weak self] in
                    self?.webView.evaluateJavaScript("document.body ? document.body.innerHTML.substring(0, 500) : 'no body'") { result, _ in
                        if let htmlPreview = result as? String {
                            print("📄 Current page HTML preview (first 500 chars): \(htmlPreview)")
                        }
                    }
                }
                
                continuation.resume(throwing: GeminiError.notReady)
                return
            }
            
            // 在主线程执行 WebView 操作
            DispatchQueue.main.async { [weak self] in
                self?.sendPrompt(prompt, model: model) { response in
                    if response.hasPrefix("Error:") {
                        continuation.resume(throwing: GeminiError.responseError(response))
                    } else {
                        continuation.resume(returning: response)
                    }
                }
            }
        }
    }
    
    enum GeminiError: LocalizedError {
        case notReady
        case responseError(String)
        
        var errorDescription: String? {
            switch self {
            case .notReady:
                return "Gemini WebView not ready or not logged in"
            case .responseError(let msg):
                return msg
            }
        }
    }
    
    /// 检查登录状态
    func checkLoginStatus() {
        let js = "window.__fetchBridge ? window.__fetchBridge.checkLogin() : false;"
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            DispatchQueue.main.async {
                self?.isLoggedIn = (result as? Bool) ?? false
                self?.connectionStatus = self?.isLoggedIn == true ? "🟢 Connected" : "🔴 Need Login"
            }
        }
    }
    
    // MARK: - Cookie Injection & Persistence
    
    /// Cookie 持久化存储的 UserDefaults Key
    private static let cookieStorageKey = "FetchGeminiCookies"
    
    /// 注入原始 Cookie 字符串 (从 Chrome 控制台 document.cookie 获取)
    func injectRawCookies(_ cookieString: String, completion: @escaping () -> Void) {
        let dataStore = WKWebsiteDataStore.default()
        let cookieStore = dataStore.httpCookieStore
        
        // 解析原始 Cookie 字符串 (key=value; key=value)
        let components = cookieString.components(separatedBy: ";")
        
        let group = DispatchGroup()
        var injectedCount = 0
        var cookiesToSave: [[String: Any]] = []
        
        for component in components {
            let parts = component.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                let name = parts[0].trimmingCharacters(in: .whitespaces)
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                
                // 构建 HTTPCookie - Domain 必须设置正确
                let properties: [HTTPCookiePropertyKey: Any] = [
                    .domain: ".google.com",
                    .path: "/",
                    .name: name,
                    .value: value,
                    .secure: "TRUE",
                    .expires: Date(timeIntervalSinceNow: 31536000) // 1年后过期
                ]
                
                if let cookie = HTTPCookie(properties: properties) {
                    group.enter()
                    cookieStore.setCookie(cookie) {
                        injectedCount += 1
                        group.leave()
                    }
                    
                    // 保存到持久化存储
                    cookiesToSave.append([
                        "name": name,
                        "value": value,
                        "domain": ".google.com",
                        "path": "/",
                        "expires": Date(timeIntervalSinceNow: 31536000).timeIntervalSince1970
                    ])
                }
            }
        }
        
        // 完成后重新加载页面
        group.notify(queue: .main) { [weak self] in
            print("🍪 Injected \(injectedCount) cookies successfully")
            
            // 持久化保存到 UserDefaults
            UserDefaults.standard.set(cookiesToSave, forKey: Self.cookieStorageKey)
            print("💾 Saved \(cookiesToSave.count) cookies to persistent storage")
            
            self?.reloadPage()
            completion()
        }
    }
    
    /// 从持久化存储恢复 Cookie (App 启动时调用)
    func restoreCookiesFromStorage(completion: @escaping () -> Void) {
        guard let savedCookies = UserDefaults.standard.array(forKey: Self.cookieStorageKey) as? [[String: Any]],
              !savedCookies.isEmpty else {
            print("📭 No saved cookies found")
            completion()
            return
        }
        
        let dataStore = WKWebsiteDataStore.default()
        let cookieStore = dataStore.httpCookieStore
        let group = DispatchGroup()
        var restoredCount = 0
        
        for cookieData in savedCookies {
            guard let name = cookieData["name"] as? String,
                  let value = cookieData["value"] as? String,
                  let domain = cookieData["domain"] as? String,
                  let path = cookieData["path"] as? String,
                  let expiresTimestamp = cookieData["expires"] as? TimeInterval else {
                continue
            }
            
            // 检查是否过期
            if Date(timeIntervalSince1970: expiresTimestamp) < Date() {
                continue
            }
            
            let properties: [HTTPCookiePropertyKey: Any] = [
                .domain: domain,
                .path: path,
                .name: name,
                .value: value,
                .secure: "TRUE",
                .expires: Date(timeIntervalSince1970: expiresTimestamp)
            ]
            
            if let cookie = HTTPCookie(properties: properties) {
                group.enter()
                cookieStore.setCookie(cookie) {
                    restoredCount += 1
                    group.leave()
                }
            }
        }
        
        group.notify(queue: .main) {
            print("🔄 Restored \(restoredCount) cookies from storage")
            completion()
        }
    }
    
    /// 重新加载 Gemini 页面
    func reloadPage() {
        connectionStatus = "Reloading..."
        if let url = URL(string: "https://gemini.google.com/app") {
            webView.load(URLRequest(url: url))
        }
    }
    
    /// 清除所有 Cookie (用于登出)
    func clearCookies(completion: @escaping () -> Void) {
        let dataStore = WKWebsiteDataStore.default()
        dataStore.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            let googleRecords = records.filter { $0.displayName.contains("google") }
            dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: googleRecords) {
                print("🗑️ Cleared Google cookies")
                completion()
            }
        }
    }
}

// MARK: - WKNavigationDelegate

extension GeminiWebManager: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("✅ Page loaded: \(webView.url?.absoluteString ?? "")")
        
        // 等待页面完全渲染
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.isReady = true
            self?.checkLoginStatus()
        }
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("❌ Navigation failed: \(error)")
        connectionStatus = "🔴 Load Failed"
    }
}

// MARK: - WKScriptMessageHandler

extension GeminiWebManager: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "geminiBridge",
              let body = message.body as? [String: Any] else { return }
        
        let type = body["type"] as? String ?? ""
        
        switch type {
        case "GEMINI_RESPONSE":
            let content = body["content"] as? String ?? ""
            let id = body["id"] as? String ?? ""
            
            print("📥 Response received (id: \(id), length: \(content.count))")
            
            DispatchQueue.main.async { [weak self] in
                self?.isProcessing = false
                self?.lastResponse = content
                self?.responseCallback?(content)
                self?.responseCallback = nil
            }
            
        case "LOGIN_STATUS":
            let loggedIn = body["loggedIn"] as? Bool ?? false
            DispatchQueue.main.async { [weak self] in
                self?.isLoggedIn = loggedIn
                self?.connectionStatus = loggedIn ? "🟢 Connected" : "🔴 Need Login"
            }
            
        case "STATUS":
            let status = body["status"] as? String ?? ""
            print("📊 Bridge Status: \(status)")
            
        default:
            print("⚠️ Unknown message type: \(type)")
        }
    }
}

// MARK: - Injected JavaScript

extension GeminiWebManager {
    /// 极简伪装脚本：只移除 WebDriver 标记，不做多余动作
    /// 过多的伪装（如伪造 window.chrome）反而会因特征不符被识别
    public static let fingerprintMaskScript = """
    (function() {
        // 仅移除自动化标记，保持 Safari 纯净特征
        if (navigator.webdriver) {
            delete navigator.webdriver;
        }
        Object.defineProperty(navigator, 'webdriver', {
            get: () => undefined,
            configurable: true
        });
        
        // 屏蔽 Notification 权限查询，防止指纹泄漏
        const originalQuery = window.Permissions.prototype.query;
        if (originalQuery) {
            window.Permissions.prototype.query = (parameters) => (
                parameters.name === 'notifications' ?
                Promise.resolve({ state: Notification.permission }) :
                originalQuery(parameters)
            );
        }
    })();
    """
    
    /// 注入到 Gemini 页面的 JavaScript (移植自 content.js v7.3)
    static let injectedScript = """
    (function() {
        console.log("🚀 Fetch Bridge v8.0 (Native) Initializing...");
        
        // 全局桥接对象
        window.__fetchBridge = {
            pendingId: null,
            
            // 发送 Prompt
            sendPrompt: async function(text, model, id) {
                this.pendingId = id;
                
                try {
                    // 模型切换 (如果需要)
                    if (model && model !== 'default') {
                        await this.switchModel(model);
                    }
                    
                    // 清理干扰弹窗
                    const buttons = Array.from(document.querySelectorAll('button'));
                    const dismissBtns = buttons.filter(b => {
                        const text = (b.innerText || '').trim();
                        const ariaLabel = b.getAttribute('aria-label') || '';
                        return text.match(/Close|No thanks|Maybe later|Got it|Dismiss|I agree|Accept/i) || 
                               ariaLabel.match(/Close|Dismiss/i);
                    });
                    dismissBtns.forEach(b => {
                        try { b.click(); } catch(e) {}
                    });
                    await this.sleep(300);
                    
                    // 找到输入框（更新选择器列表）
                    const inputArea = await this.waitForElement([
                        'div[contenteditable="true"]',
                        'rich-textarea',
                        'div[role="textbox"]',
                        'rich-textarea div p',
                        'textarea[aria-label*="message"]'
                    ]);
                    
                    inputArea.focus();
                    await this.sleep(100);
                    
                    // 清空并输入
                    document.execCommand('selectAll', false, null);
                    document.execCommand('delete', false, null);
                    await this.sleep(50);
                    
                    // 拟人化逐字输入
                    for (const char of text) {
                        document.execCommand('insertText', false, char);
                        await this.sleep(Math.random() * 15 + 5);
                    }
                    
                    await this.sleep(300);
                    
                    // 发送
                    const sendBtn = document.querySelector('button[aria-label*="Send"], button[aria-label*="发送"], .send-button');
                    if (sendBtn && !sendBtn.disabled) {
                        sendBtn.click();
                    } else {
                        inputArea.dispatchEvent(new KeyboardEvent('keydown', {
                            keyCode: 13, key: 'Enter', code: 'Enter', bubbles: true
                        }));
                    }
                    
                    // 等待响应
                    await this.waitForResponse(id);
                    
                } catch (e) {
                    console.error("❌ Error:", e);
                    this.postToSwift({ type: 'GEMINI_RESPONSE', id: id, content: 'Error: ' + e.message });
                }
            },
            
            // 模型切换
            switchModel: async function(targetModel) {
                const MODEL_MAP = {
                    'flash': ['Flash', 'Fast', '2.0 Flash'],
                    'pro': ['Pro', '1.5 Pro', '2.5 Pro'],
                    'thinking': ['Thinking', 'Deep Research'],
                    'advanced': ['Advanced']
                };
                
                const targetKey = Object.keys(MODEL_MAP).find(k => targetModel.toLowerCase().includes(k));
                if (!targetKey) return;
                
                const labels = MODEL_MAP[targetKey];
                
                // 找下拉按钮
                const buttons = Array.from(document.querySelectorAll('button, [role="button"]'));
                const dropdown = buttons.find(btn => {
                    const text = (btn.innerText || "").trim();
                    return (text.includes("Gemini") || text.includes("Flash") || text.includes("Pro")) && text.length < 30;
                });
                
                if (!dropdown) return;
                
                dropdown.click();
                await this.sleep(800);
                
                const options = Array.from(document.querySelectorAll('[role="menuitem"], [role="option"], mat-option'));
                const target = options.find(opt => labels.some(l => opt.innerText.toLowerCase().includes(l.toLowerCase())));
                
                if (target) {
                    target.click();
                    await this.sleep(500);
                    
                    // 确认弹窗
                    const confirm = Array.from(document.querySelectorAll('button')).find(b => 
                        b.innerText.toLowerCase().includes('switch') || b.innerText.toLowerCase().includes('ok')
                    );
                    if (confirm) confirm.click();
                    
                    await this.sleep(1000);
                }
            },
            
            // 等待响应完成
            waitForResponse: function(id) {
                return new Promise((resolve) => {
                    let hasStarted = false;
                    let silenceTimer = null;
                    const startTime = Date.now();
                    const self = this;
                    
                    const observer = new MutationObserver(() => {
                        const stopBtn = document.querySelector('button[aria-label*="Stop"]');
                        
                        if (stopBtn) {
                            hasStarted = true;
                            if (silenceTimer) { clearTimeout(silenceTimer); silenceTimer = null; }
                        } else if (hasStarted) {
                            if (!silenceTimer) {
                                silenceTimer = setTimeout(() => finish(), 1500);
                            }
                        } else if (Date.now() - startTime > 15000) {
                            observer.disconnect();
                            self.postToSwift({ type: 'GEMINI_RESPONSE', id: id, content: 'Error: Timeout' });
                            resolve();
                        }
                    });
                    
                    const finish = () => {
                        observer.disconnect();
                        
                        let text = "";
                        const responses = document.querySelectorAll('model-response');
                        if (responses.length > 0) {
                            const last = responses[responses.length - 1];
                            const md = last.querySelector('.markdown');
                            text = md ? md.textContent : last.innerText;
                            text = text.replace(/Show thinking/g, '').replace(/Gemini can make mistakes.*$/gim, '').trim();
                        }
                        
                        self.postToSwift({ type: 'GEMINI_RESPONSE', id: id, content: text || 'Error: No response' });
                        resolve();
                    };
                    
                    observer.observe(document.body, { childList: true, subtree: true, characterData: true });
                    setTimeout(() => { observer.disconnect(); if (hasStarted) finish(); else resolve(); }, 60000);
                });
            },
            
            // 检查登录状态
            checkLogin: function() {
                const loggedIn = !document.querySelector('a[href*="accounts.google.com"]');
                this.postToSwift({ type: 'LOGIN_STATUS', loggedIn: loggedIn });
                return loggedIn;
            },
            
            // 发送消息到 Swift
            postToSwift: function(data) {
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.geminiBridge) {
                    window.webkit.messageHandlers.geminiBridge.postMessage(data);
                }
            },
            
            // 工具函数
            sleep: function(ms) { return new Promise(r => setTimeout(r, ms)); },
            
            waitForElement: async function(selectors, timeout = 5000) {
                const start = Date.now();
                while (Date.now() - start < timeout) {
                    for (const sel of selectors) {
                        const el = document.querySelector(sel);
                        if (el) return el;
                    }
                    await this.sleep(100);
                }
                throw new Error("Element not found");
            }
        };
        
        // 初始化检查
        setTimeout(() => {
            window.__fetchBridge.checkLogin();
            window.__fetchBridge.postToSwift({ type: 'STATUS', status: 'ready' });
        }, 2000);
        
        console.log("✅ Fetch Bridge Ready");
    })();
    """
}

