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
@MainActor
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
    /// 使用 MagicPaster (剪贴板+Cmd+V+Enter) 替代JS注入，更稳定可靠
    func sendPrompt(_ text: String, model: String = "default", completion: @escaping (String) -> Void) {
        guard isReady && isLoggedIn else {
            completion("Error: Gemini not ready or not logged in")
            return
        }
        
        isProcessing = true
        pendingPromptId = UUID().uuidString
        responseCallback = completion
        
        // 统一输入流: 使用剪贴板 + 模拟键盘，不依赖DOM选择器
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // 1. 将Prompt写入剪贴板
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            
            // 2. 聚焦浏览器窗口
            if let window = self.webView.window {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            
            // 3. 等待窗口激活后，使用MagicPaster发送
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                // 先清理弹窗（如果存在）
                self.cleanupPopups { [weak self] in
                    guard let self = self else { return }
                    
                    // 等待输入框聚焦
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        // 使用MagicPaster模拟 Cmd+V + Enter
                        MagicPaster.shared.pasteToBrowser()
                        
                        // 等待响应（通过JS监听）
                        self.waitForResponse(id: self.pendingPromptId!)
                    }
                }
            }
        }
    }
    
    /// 清理干扰弹窗（通过JS）
    private func cleanupPopups(completion: @escaping () -> Void) {
        let cleanupScript = """
        (function() {
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
        })();
        """
        
        webView.evaluateJavaScript(cleanupScript) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                completion()
            }
        }
    }
    
    /// 等待Gemini响应完成
    private func waitForResponse(id: String) {
        let waitScript = """
        window.__fetchBridge.waitForResponse("\(id)");
        """
        
        webView.evaluateJavaScript(waitScript) { _, error in
                if let error = error {
                print("❌ Wait script error: \(error)")
                DispatchQueue.main.async { [weak self] in
                    self?.isProcessing = false
                    self?.responseCallback?("Error: \(error.localizedDescription)")
                    self?.responseCallback = nil
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
        webView.evaluateJavaScript(js) { [weak self] result, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("⚠️ Login check error: \(error.localizedDescription)")
                }
                
                // 处理返回结果（可能是 Bool 或包含调试信息的对象）
                if let loggedIn = result as? Bool {
                    self?.isLoggedIn = loggedIn
                    self?.connectionStatus = loggedIn ? "🟢 Connected" : "🔴 Need Login"
                } else if let resultDict = result as? [String: Any] {
                    // 如果返回了调试信息
                    let loggedIn = resultDict["loggedIn"] as? Bool ?? false
                    self?.isLoggedIn = loggedIn
                    self?.connectionStatus = loggedIn ? "🟢 Connected" : "🔴 Need Login"
                    
                    if let debug = resultDict["debug"] as? [String: Any] {
                        print("🔍 Login Debug - URL: \(debug["url"] ?? "unknown"), HasInputBox: \(debug["hasInputBox"] ?? false)")
                    }
                } else {
                    // 如果 JS 返回了其他格式，尝试从消息处理器获取
                    print("⚠️ Unexpected login check result type")
                }
                
                // 额外检查：如果 URL 包含 gemini.google.com，强制设为已登录
                self?.webView.evaluateJavaScript("window.location.href") { urlResult, _ in
                    if let urlString = urlResult as? String,
                       urlString.contains("gemini.google.com") &&
                       !urlString.contains("accounts.google.com") &&
                       !urlString.contains("signin") {
                        DispatchQueue.main.async {
                            if let self = self, !self.isLoggedIn {
                                print("🔧 Force setting loggedIn=true based on URL: \(urlString)")
                                self.isLoggedIn = true
                                self.connectionStatus = "🟢 Connected"
                            }
                        }
                    }
                }
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
        let urlString = webView.url?.absoluteString ?? ""
        print("✅ Page loaded: \(urlString)")
        
        // 如果加载的是 Gemini 页面，立即检查登录状态
        if urlString.contains("gemini.google.com") && !urlString.contains("accounts.google.com") {
            print("📍 Detected Gemini page, checking login status...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.checkLoginStatus()
            }
        }
        
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
            if let debug = body["debug"] as? [String: Any] {
                let url = debug["url"] as? String ?? "unknown"
                let hasInputBox = debug["hasInputBox"] as? Bool ?? false
                print("🔍 Login Status Update - URL: \(url), HasInputBox: \(hasInputBox), LoggedIn: \(loggedIn)")
            }
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
    
    /// 注入到 Gemini 页面的 JavaScript (v9.0 - MagicPaster模式)
    /// 不再使用JS逐字输入，改为监听响应
    static let injectedScript = """
    (function() {
        console.log("🚀 Fetch Bridge v9.0 (MagicPaster Mode) Initializing...");
        
        // 全局桥接对象
        window.__fetchBridge = {
            pendingId: null,
            
            // 等待响应（输入由MagicPaster完成，这里只负责监听）
            waitForResponse: function(id) {
                this.pendingId = id;
                const self = this;
                
                let hasStarted = false;
                let silenceTimer = null;
                const startTime = Date.now();
                
                const observer = new MutationObserver(() => {
                    const stopBtn = document.querySelector('button[aria-label*="Stop"], button[aria-label*="停止"]');
                    
                    if (stopBtn) {
                        hasStarted = true;
                        if (silenceTimer) { 
                            clearTimeout(silenceTimer); 
                            silenceTimer = null; 
                        }
                    } else if (hasStarted) {
                        if (!silenceTimer) {
                            silenceTimer = setTimeout(() => finish(), 1500);
                        }
                    } else if (Date.now() - startTime > 15000) {
                        observer.disconnect();
                        self.postToSwift({ 
                            type: 'GEMINI_RESPONSE', 
                            id: id, 
                            content: 'Error: Timeout waiting for response' 
                        });
                    }
                });
                
                const finish = () => {
                    observer.disconnect();
                    
                    let text = "";
                    
                    // 多重策略：尝试多种选择器
                    const selectors = [
                        'model-response',
                        '[data-model-response]',
                        '.model-response',
                        'div[role="textbox"]',
                        '.message-content',
                        '.text-content',
                        'div[contenteditable="false"]'
                    ];
                    
                    let lastResponse = null;
                    for (const selector of selectors) {
                        const elements = document.querySelectorAll(selector);
                        if (elements.length > 0) {
                            lastResponse = elements[elements.length - 1];
                            console.log(`✅ Found response using selector: ${selector}`);
                            break;
                        }
                    }
                    
                    if (lastResponse) {
                        // 优先查找 markdown 容器
                        const md = lastResponse.querySelector('.markdown, [class*="markdown"], .markdown-container');
                        if (md) {
                            text = md.textContent || md.innerText;
                        } else {
                            text = lastResponse.textContent || lastResponse.innerText;
                        }
                        
                        // 清理文本 (使用 JavaScript 字符串方法)
                        text = text.replace(/Show thinking/gi, '')
                                   .replace(/Gemini can make mistakes.*$/gim, '')
                                   .replace(/^\\s*Thinking\\s*$/gim, '');
                        text = text.trim();
                    }
                    
                    // 如果仍然没有找到，记录调试信息
                    if (!text || text.length === 0) {
                        console.warn('⚠️ No response text found, collecting debug info...');
                        
                        // 收集页面结构摘要
                        const debugInfo = {
                            url: window.location.href,
                            title: document.title,
                            bodyClasses: document.body.className,
                            foundElements: {}
                        };
                        
                        selectors.forEach(sel => {
                            const count = document.querySelectorAll(sel).length;
                            if (count > 0) {
                                debugInfo.foundElements[sel] = count;
                            }
                        });
                        
                        // 查找所有可能的文本容器
                        const textContainers = Array.from(document.querySelectorAll('div, p, span'))
                            .filter(el => {
                                const txt = el.textContent || '';
                                return txt.length > 50 && txt.length < 5000;
                            })
                            .slice(-3)
                            .map(el => ({
                                tag: el.tagName,
                                classes: el.className,
                                textPreview: (el.textContent || '').substring(0, 100)
                            }));
                        
                        debugInfo.recentTextContainers = textContainers;
                        console.log('🔍 Debug Info:', JSON.stringify(debugInfo, null, 2));
                        
                        // 尝试从最后一个文本容器提取
                        if (textContainers.length > 0) {
                            const lastContainer = document.querySelectorAll('div, p, span')
                                .item(document.querySelectorAll('div, p, span').length - 1);
                            if (lastContainer) {
                                text = (lastContainer.textContent || '').trim();
                                console.log('📝 Extracted text from fallback container');
                            }
                        }
                    }
                    
                    self.postToSwift({ 
                        type: 'GEMINI_RESPONSE', 
                        id: id, 
                        content: text || 'Error: No response detected. Check console for debug info.' 
                    });
                };
                
                observer.observe(document.body, { 
                    childList: true, 
                    subtree: true, 
                    characterData: true 
                });
                
                // 超时保护
                setTimeout(() => { 
                    observer.disconnect(); 
                    if (hasStarted) finish(); 
                }, 60000);
            },
            
            // 模型切换（保留，但不再在sendPrompt中调用）
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
            
            // 检查登录状态（改进版：多重检测）
            checkLogin: function() {
                const currentURL = window.location.href;
                const pageTitle = document.title;
                
                // 方法1: URL 检查 - 只要在 Gemini 域名下就初步通过
                const isOnGeminiDomain = currentURL.includes('gemini.google.com') && 
                                        !currentURL.includes('accounts.google.com') &&
                                        !currentURL.includes('signin');
                
                // 方法2: DOM 检查 - 查找 Gemini 输入框（恒定特征）
                const hasInputBox = !!document.querySelector('div[contenteditable="true"]');
                
                // 方法3: 检查是否有登录链接（旧方法，作为反向验证）
                const hasLoginLink = !!document.querySelector('a[href*="accounts.google.com"]');
                
                // 综合判断：在 Gemini 域名 + 有输入框 = 已登录
                // 或者：在 Gemini 域名 + 没有登录链接 = 已登录
                const loggedIn = isOnGeminiDomain && (hasInputBox || !hasLoginLink);
                
                // 调试信息
                console.log('🔍 Login Check:', {
                    url: currentURL,
                    title: pageTitle,
                    isOnGeminiDomain: isOnGeminiDomain,
                    hasInputBox: hasInputBox,
                    hasLoginLink: hasLoginLink,
                    loggedIn: loggedIn
                });
                
                this.postToSwift({ 
                    type: 'LOGIN_STATUS', 
                    loggedIn: loggedIn,
                    debug: {
                        url: currentURL,
                        title: pageTitle,
                        hasInputBox: hasInputBox
                    }
                });
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

