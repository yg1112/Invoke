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

/// Native Gemini Bridge - v28.0 (MutationObserver & Event Driven)
/// 核心升级：
/// 1. 弃用 Polling (轮询)，启用 MutationObserver (变动观察者)。
/// 2. 原理：监听 DOM 树的每一次微小变动。只有当变动完全停止 (Silence) 超过阈值时，才认定为响应结束。
/// 3. 这是浏览器底层最本质的"渲染感知"方式，比时间猜测准确度高 100倍。
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
        let isFromAider: Bool  // 标记是否来自 Aider，避免循环
        let continuation: CheckedContinuation<String, Error>
    }
    
    private var requestStream: AsyncStream<PendingRequest>.Continuation?
    private var requestTask: Task<Void, Never>?
    private var watchdogTimer: Timer?

    // 标记当前请求是否来自 Aider（避免循环：Aider 请求不应触发 processResponse）
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

        self.requestTask = Task {
            for await request in stream {
                while !self.isReady { try? await Task.sleep(nanoseconds: 500_000_000) }

                // 设置标记：当前请求是否来自 Aider
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

                // 重置标记
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
        debugWindow?.title = "Fetch Debugger (v29 Structural Location)"
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
                
                // 90秒兜底，防止 MutationObserver 彻底死锁（虽然极罕见）
                self.watchdogTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                    print("⏰ Timeout. Force scrape...")
                    Task { @MainActor in
                        self?.forceScrape(id: promptId)
                    }
                }
                
                let escapedText = text.replacingOccurrences(of: "\\", with: "\\\\")
                                      .replacingOccurrences(of: "\"", with: "\\\"")
                                      .replacingOccurrences(of: "\n", with: "\\n")

                let js = "window.__fetchBridge.sendPrompt(\"\(escapedText)\", \"\(promptId)\");"
                print("📤 [GeminiWebManager] Executing JS: sendPrompt (id=\(promptId.prefix(8))...)")
                self.webView.evaluateJavaScript(js) { result, error in
                    if let error = error {
                        print("   ❌ JS Error: \(error.localizedDescription)")
                    } else {
                        print("   ✅ JS executed successfully")
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
        
        // 解析 cookie 字符串（支持多种格式）
        let cookies = parseCookieString(cookieString)
        
        for cookie in cookies {
            group.enter()
            store.setCookie(cookie) {
                group.leave()
            }
        }
        
        // 保存到 UserDefaults
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
            // 重新加载页面以应用 cookies
            self.reloadPage()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                completion()
            }
        }
    }
    
    private func parseCookieString(_ cookieString: String) -> [HTTPCookie] {
        var cookies: [HTTPCookie] = []
        
        // 尝试解析 JSON 格式
        if let jsonData = cookieString.data(using: .utf8),
           let jsonArray = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] {
            for item in jsonArray {
                if let cookie = parseCookieDict(item) {
                    cookies.append(cookie)
                }
            }
            return cookies
        }
        
        // 尝试解析 Netscape 格式或简单格式
        let lines = cookieString.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            
            // 尝试解析 "name=value; domain=.example.com; path=/"
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
            let isFromAider = self.isCurrentRequestFromAider  // 捕获当前标记
            DispatchQueue.main.async { [weak self] in
                if let callback = self?.responseCallback {
                    callback(content.isEmpty ? "Error: Empty response" : content)
                    self?.responseCallback = nil

                    // 只有非 Aider 请求才触发 processResponse，避免无限循环
                    if !isFromAider && !content.isEmpty && !content.hasPrefix("Error:") {
                        print("📋 [GeminiWebManager] Triggering processResponse (user request)")
                        GeminiLinkLogic.shared.processResponse(content)
                    } else if isFromAider {
                        print("⏭️ [GeminiWebManager] Skipping processResponse (Aider request)")
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

// MARK: - Injected Scripts (V29 - Structural Location)
extension GeminiWebManager {
    static let fingerprintMaskScript = """
    (function() {
        if (navigator.webdriver) { delete navigator.webdriver; }
        Object.defineProperty(navigator, 'webdriver', { get: () => undefined, configurable: true });
    })();
    """
    
    /// v29 - Relative Structural Location Strategy
    /// 核心升级：
    /// 1. 定位锚点：通过精确文本匹配找到用户发送的消息元素
    /// 2. 提取回复：获取用户消息的下一个兄弟元素（AI回复）
    /// 3. 完成信号：监控按钮状态（Stop按钮消失 + Send按钮启用 = 生成完成）
    static let injectedScript = """
    (function() {
        console.log("🚀 Bridge v29 (Structural Location) Initializing...");

        window.__fetchBridge = {
            // ===== 状态变量 =====
            state: 'idle',  // idle | sending | generating | complete
            currentPromptId: null,
            lastSentText: '',
            buttonObserver: null,
            pollInterval: null,
            graceTimeout: null,
            userPromptElement: null,
            generationStartTime: null,
            inGracePeriod: false,
            stopButtonEverSeen: false,
            // ===== 防止重复响应 =====
            lastResponseContent: null,
            lastResponseTime: 0,

            // ===== 工具函数 =====
            log: function(msg) {
                console.log('[FetchBridge] ' + msg);
                this.postToSwift({ type: 'LOG', message: msg });
            },

            postToSwift: function(data) {
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.geminiBridge) {
                    window.webkit.messageHandlers.geminiBridge.postMessage(data);
                }
            },

            // ===== 主入口 =====
            sendPrompt: function(text, id) {
                try {
                    this.log("📤 sendPrompt called. State: " + this.state + ", ID: " + id);

                    // 强制重置，确保干净状态
                    this.reset();

                    this.state = 'sending';
                    this.currentPromptId = id;
                    this.lastSentText = text.trim();
                    this.generationStartTime = Date.now();

                    // 1. 注入文本并发送
                    const success = this.injectAndSend(text);
                    if (!success) {
                        this.finish(id, 'Error: Failed to inject text');
                        return;
                    }

                    // 2. 启动完成检测
                    this.startCompletionDetection(id);
                } catch (e) {
                    this.log("❌ sendPrompt error: " + e.message);
                    this.finish(id, 'Error: ' + e.message);
                }
            },

            // ===== Part 0: 注入文本并发送 (Enhanced Event Dispatch) =====
            injectAndSend: function(text) {
                const input = document.querySelector('div[contenteditable="true"]');
                if (!input) {
                    this.log("❌ Input box not found");
                    return false;
                }

                const self = this;

                // 聚焦
                input.focus();

                // 方法1：尝试 execCommand
                document.execCommand('selectAll', false, null);
                document.execCommand('delete', false, null);
                document.execCommand('insertText', false, text);

                // 方法2：直接设置内容（备用）
                if (!input.innerText || input.innerText.trim() !== text.trim()) {
                    input.innerText = text;
                }

                // ===== 关键：触发框架的变更检测 =====
                // 派发多种事件，确保 React/Angular/Vue 等框架能检测到变化
                input.dispatchEvent(new Event('input', { bubbles: true, cancelable: true }));
                input.dispatchEvent(new Event('change', { bubbles: true, cancelable: true }));
                input.dispatchEvent(new InputEvent('input', {
                    bubbles: true,
                    cancelable: true,
                    inputType: 'insertText',
                    data: text
                }));

                // 模拟键盘输入结束
                input.dispatchEvent(new KeyboardEvent('keyup', {
                    bubbles: true, cancelable: true, keyCode: 65, key: 'a'
                }));

                this.log("📝 Text injected, events dispatched");

                // 关闭可能的弹窗
                input.dispatchEvent(new KeyboardEvent('keydown', {
                    bubbles: true, cancelable: true, keyCode: 27, key: 'Escape'
                }));

                // 延迟发送（等待UI更新 + 框架响应）
                setTimeout(() => {
                    self.attemptSend(input, 1);
                }, 400);

                return true;
            },

            // ===== 发送尝试（支持重试）=====
            attemptSend: function(input, attempt) {
                const self = this;
                const maxAttempts = 3;

                this.log("📤 Send attempt " + attempt + "/" + maxAttempts);

                // 查找发送按钮
                const sendBtn = document.querySelector(
                    'button[aria-label*="Send"], button[aria-label*="send"], ' +
                    'button[data-tooltip*="Send"], button[class*="send"]'
                );

                let sent = false;

                if (sendBtn && !sendBtn.disabled) {
                    sendBtn.click();
                    this.log("👆 Clicked Send Button");
                    sent = true;
                } else {
                    // 备用：按回车
                    const enter = new KeyboardEvent('keydown', {
                        bubbles: true, cancelable: true, keyCode: 13, key: 'Enter'
                    });
                    input.dispatchEvent(enter);
                    this.log("⌨️ Pressed Enter");
                    sent = true;
                }

                this.state = 'generating';
                this.log("⚡ State -> generating");

                // 检查是否成功触发生成（Stop 按钮应该出现）
                setTimeout(() => {
                    // 状态检查：如果已重置，不继续
                    if (self.state === 'idle') return;

                    const stopBtn = document.querySelector(
                        'button[aria-label*="Stop"], button[aria-label*="stop"], ' +
                        'button[data-tooltip*="Stop"]'
                    );

                    if (stopBtn && stopBtn.offsetParent !== null) {
                        self.log("✅ Generation confirmed (Stop button visible)");
                        self.stopButtonEverSeen = true;
                    } else if (attempt < maxAttempts && self.state === 'generating') {
                        // 没有看到 Stop 按钮，重试发送
                        self.log("⚠️ Stop button not seen, retrying send...");

                        // 重新触发事件
                        input.dispatchEvent(new Event('input', { bubbles: true }));

                        setTimeout(() => {
                            if (self.state === 'idle') return;  // 状态检查
                            self.attemptSend(input, attempt + 1);
                        }, 500);
                    } else if (self.state === 'generating') {
                        self.log("⚠️ Max send attempts reached, proceeding anyway");
                    }
                }, 800);
            },

            // ===== Part 1: 定位用户消息元素（锚点）- SUBSTRING STRATEGY =====
            findUserPromptElement: function(text) {
                const searchText = text.trim();
                // ===== 关键改进：只用前20个字符匹配 =====
                const searchPrefix = this.normalizeText(searchText).substring(0, 20);
                this.log("🔍 Searching for user prompt (prefix): '" + searchPrefix + "'");

                const mainEl = document.querySelector('main');
                if (!mainEl) {
                    this.log("⚠️ main element not found");
                    return null;
                }

                // 收集所有包含前缀的候选元素
                const candidates = [];

                const allElements = mainEl.querySelectorAll('*');
                for (let i = 0; i < allElements.length; i++) {
                    const el = allElements[i];
                    if (!el.innerText) continue;

                    const elText = el.innerText.trim();

                    // 跳过太长的容器（可能是整个聊天区域）
                    if (elText.length > 2000) continue;

                    // 跳过太短的元素
                    if (elText.length < 5) continue;

                    const normalizedEl = this.normalizeText(elText);

                    // ===== 核心匹配：检查元素是否包含搜索前缀 =====
                    if (normalizedEl.includes(searchPrefix)) {
                        // 计算匹配质量（越接近精确匹配越好）
                        const lengthRatio = Math.min(searchText.length, elText.length) /
                                           Math.max(searchText.length, elText.length);

                        candidates.push({
                            element: el,
                            score: lengthRatio,
                            index: i,
                            textLength: elText.length
                        });
                    }
                }

                // 按得分+位置排序：优先最后出现的匹配（最新消息）
                candidates.sort((a, b) => {
                    // 首先按文本长度相似度排序
                    if (Math.abs(a.score - b.score) > 0.3) {
                        return b.score - a.score;
                    }
                    // 长度相似时，取最后出现的
                    return b.index - a.index;
                });

                if (candidates.length === 0) {
                    this.log("⚠️ No prefix match found for '" + searchPrefix + "'");
                    // 尝试备用策略：只匹配前10个字符
                    return this.findUserPromptElementFallback(searchText);
                }

                const bestMatch = candidates[0];
                this.log("✅ Prefix match found (score: " + bestMatch.score.toFixed(2) +
                         ", len: " + bestMatch.textLength + ")");

                // 向上遍历找到消息容器
                let container = bestMatch.element;
                let depth = 0;
                const maxDepth = 10;

                while (container && depth < maxDepth) {
                    const parent = container.parentElement;
                    if (parent) {
                        const nextSibling = container.nextElementSibling;
                        // 找到有兄弟元素的层级（消息列表）
                        if (nextSibling && nextSibling.innerText && nextSibling.innerText.length > 0) {
                            // 验证兄弟不是用户自己的消息（不包含搜索前缀）
                            const siblingNorm = this.normalizeText(nextSibling.innerText);
                            if (!siblingNorm.includes(searchPrefix)) {
                                this.log("✅ Found message container at depth " + depth);
                                return container;
                            }
                        }
                    }
                    container = parent;
                    depth++;
                }

                // 回退：返回最佳匹配元素的最近DIV父元素
                container = bestMatch.element;
                while (container && container.tagName !== 'DIV' && container.parentElement) {
                    container = container.parentElement;
                }

                this.log("📍 Using fallback container from prefix match");
                return container;
            },

            // ===== 备用锚点查找（更宽松）=====
            findUserPromptElementFallback: function(text) {
                const searchPrefix = this.normalizeText(text).substring(0, 10);  // 只用前10个字符
                this.log("🔄 Fallback search with prefix: '" + searchPrefix + "'");

                const mainEl = document.querySelector('main');
                if (!mainEl) return null;

                const allElements = mainEl.querySelectorAll('*');
                let bestMatch = null;
                let bestIndex = -1;

                for (let i = 0; i < allElements.length; i++) {
                    const el = allElements[i];
                    if (!el.innerText) continue;

                    const normalizedEl = this.normalizeText(el.innerText);

                    if (normalizedEl.includes(searchPrefix) && el.innerText.length < 2000) {
                        // 取最后出现的匹配
                        bestMatch = el;
                        bestIndex = i;
                    }
                }

                if (bestMatch) {
                    this.log("✅ Fallback found match at index " + bestIndex);
                    // 向上找到DIV容器
                    let container = bestMatch;
                    while (container && container.tagName !== 'DIV' && container.parentElement) {
                        container = container.parentElement;
                    }
                    return container;
                }

                this.log("⚠️ Fallback also failed");
                return null;
            },

            // 文本归一化（去除多余空白、换行等）
            normalizeText: function(text) {
                return text.replace(/\\s+/g, ' ').trim().toLowerCase();
            },

            // ===== Part 2: 获取AI回复元素（目标） =====
            getResponseElement: function() {
                // 状态检查：如果不在生成/完成状态，不执行
                if (this.state === 'idle') {
                    return null;
                }

                // 先尝试找到用户消息元素
                if (!this.userPromptElement) {
                    this.userPromptElement = this.findUserPromptElement(this.lastSentText);
                }

                if (!this.userPromptElement) {
                    this.log("⚠️ User prompt element not found, using fallback");
                    return this.getFallbackResponse();
                }

                // 策略1：直接获取下一个兄弟元素
                let response = this.userPromptElement.nextElementSibling;
                if (response && response.innerText && response.innerText.trim().length > 0) {
                    // 确保不是用户自己的消息
                    if (response.innerText.trim() !== this.lastSentText) {
                        this.log("✅ Found response as direct sibling");
                        return response;
                    }
                }

                // 策略2：向上一级找兄弟
                if (this.userPromptElement.parentElement) {
                    response = this.userPromptElement.parentElement.nextElementSibling;
                    if (response && response.innerText && response.innerText.trim().length > 0) {
                        if (response.innerText.trim() !== this.lastSentText) {
                            this.log("✅ Found response as parent's sibling");
                            return response;
                        }
                    }
                }

                // 策略3：备用方案
                return this.getFallbackResponse();
            },

            // ===== 备用回复提取（过滤 Disclaimer）=====
            getFallbackResponse: function() {
                this.log("🔄 Using fallback response extraction (with disclaimer filter)");

                const mainEl = document.querySelector('main');
                if (!mainEl) return null;

                // 黑名单：这些文本表示是 disclaimer/boilerplate，不是真正的回复
                const disclaimerPatterns = [
                    'sign in',
                    'google',
                    'capabilities',
                    'limitations',
                    'i can help',
                    'i\\'m an ai',
                    'i am an ai',
                    'as an ai',
                    'terms of service',
                    'privacy policy',
                    'learn more',
                    'get started',
                    'welcome to',
                    'try asking',
                    'here are some things'
                ];

                // 检查文本是否是 disclaimer
                const isDisclaimer = (text) => {
                    if (!text) return true;
                    const lower = text.toLowerCase();
                    // 太短的内容可能是 disclaimer
                    if (text.length < 20) return true;
                    // 包含黑名单词汇
                    for (const pattern of disclaimerPatterns) {
                        if (lower.includes(pattern)) return true;
                    }
                    return false;
                };

                // 检查是否是用户自己的消息
                const isUserMessage = (text) => {
                    if (!text) return false;
                    const normalized = this.normalizeText(text);
                    const userNormalized = this.normalizeText(this.lastSentText);
                    return normalized === userNormalized ||
                           normalized.includes(userNormalized) ||
                           userNormalized.includes(normalized);
                };

                // 策略1：深度搜索，找到最可能是回复的元素
                const allDivs = mainEl.querySelectorAll('div');
                const candidates = [];

                for (let i = allDivs.length - 1; i >= 0; i--) {
                    const div = allDivs[i];
                    const text = div.innerText ? div.innerText.trim() : '';

                    // 跳过空内容
                    if (text.length < 10) continue;

                    // 跳过太大的容器
                    if (div.querySelectorAll('div').length > 20) continue;

                    // 跳过 disclaimer
                    if (isDisclaimer(text)) continue;

                    // 跳过用户消息
                    if (isUserMessage(text)) continue;

                    // 看起来像回复的特征：
                    // - 有一定长度
                    // - 不是整个页面
                    // - 不包含用户的问题
                    candidates.push({
                        element: div,
                        textLength: text.length,
                        depth: this.getElementDepth(div),
                        index: i
                    });
                }

                // 按 textLength 排序（中等长度优先），避免选中整个页面
                candidates.sort((a, b) => {
                    // 优先选择深度较大的（更具体的元素）
                    if (Math.abs(a.depth - b.depth) > 2) {
                        return b.depth - a.depth;
                    }
                    // 同深度时，选择最后出现的
                    return b.index - a.index;
                });

                if (candidates.length > 0) {
                    const best = candidates[0];
                    this.log("✅ Fallback found candidate with depth " + best.depth + ", length " + best.textLength);
                    return best.element;
                }

                // 策略2：简单回退，取 main 的最后几个直接子元素
                const children = Array.from(mainEl.children);
                for (let i = children.length - 1; i >= 0; i--) {
                    const child = children[i];
                    const text = child.innerText ? child.innerText.trim() : '';

                    if (text.length > 20 && !isDisclaimer(text) && !isUserMessage(text)) {
                        this.log("✅ Fallback using direct child at index " + i);
                        return child;
                    }
                }

                this.log("⚠️ Fallback could not find valid response");
                return null;
            },

            // 获取元素在 DOM 树中的深度
            getElementDepth: function(el) {
                let depth = 0;
                let current = el;
                while (current && current.parentElement) {
                    depth++;
                    current = current.parentElement;
                }
                return depth;
            },

            // ===== Part 3: 按钮状态检测 =====
            isGenerating: function() {
                // 检查 Stop 按钮是否存在（生成中会显示）
                const stopBtn = document.querySelector(
                    'button[aria-label*="Stop"], button[aria-label*="stop"], ' +
                    'button[data-tooltip*="Stop"], button[title*="Stop"], ' +
                    'button[aria-label*="Cancel"], button[aria-label*="cancel"]'
                );
                if (stopBtn && stopBtn.offsetParent !== null) {
                    return true;
                }

                // 检查 Send 按钮是否禁用
                const sendBtn = document.querySelector(
                    'button[aria-label*="Send"], button[aria-label*="send"], ' +
                    'button[data-tooltip*="Send"]'
                );
                if (sendBtn && sendBtn.disabled) {
                    return true;
                }

                // 检查是否有 "Thinking" 或加载指示器
                const mainEl = document.querySelector('main');
                if (mainEl) {
                    const text = mainEl.innerText;
                    if (text.includes('Thinking') || text.includes('...')) {
                        // 但要排除已经有实质内容的情况
                        const responseEl = this.getResponseElement();
                        if (responseEl) {
                            const responseText = responseEl.innerText.trim();
                            // 如果回复只是 "Thinking..." 则还在生成
                            if (responseText === 'Thinking...' || responseText === 'Thinking' || responseText.length < 5) {
                                return true;
                            }
                        }
                    }
                }

                return false;
            },

            // ===== 启动完成检测 (带 Grace Period) =====
            startCompletionDetection: function(id) {
                const self = this;
                this.log("👀 Starting completion detection with grace period");

                // 清理旧的观察者
                if (this.buttonObserver) this.buttonObserver.disconnect();
                if (this.pollInterval) clearInterval(this.pollInterval);
                if (this.graceTimeout) clearTimeout(this.graceTimeout);

                // ========== GRACE PERIOD ==========
                // 在前2秒内，忽略所有"完成"信号
                // 这给 Stop 按钮足够时间渲染到 DOM
                this.inGracePeriod = true;
                this.stopButtonEverSeen = false;

                this.graceTimeout = setTimeout(() => {
                    // 状态检查：如果已重置，不继续
                    if (self.state === 'idle') return;

                    self.inGracePeriod = false;
                    self.log("⏱️ Grace period ended, now monitoring for completion");

                    // Grace period 结束后，如果从未见过 Stop 按钮，等待更长时间
                    if (!self.stopButtonEverSeen) {
                        self.log("⚠️ Stop button never seen, extending wait...");
                    }
                }, 2000);  // 2秒 grace period

                // MutationObserver 监控按钮状态变化
                this.buttonObserver = new MutationObserver(function(mutations) {
                    // 检测 Stop 按钮是否出现过
                    const stopBtn = document.querySelector(
                        'button[aria-label*="Stop"], button[aria-label*="stop"], ' +
                        'button[data-tooltip*="Stop"], button[title*="Stop"], ' +
                        'button[aria-label*="Cancel"]'
                    );
                    if (stopBtn && stopBtn.offsetParent !== null) {
                        if (!self.stopButtonEverSeen) {
                            self.log("👁️ Stop button detected - generation confirmed");
                        }
                        self.stopButtonEverSeen = true;
                    }

                    // 在 grace period 内，不触发完成
                    if (self.inGracePeriod) {
                        return;
                    }

                    // 只有当 Stop 按钮曾经出现过，现在消失了，才算完成
                    if (self.state === 'generating' && self.stopButtonEverSeen && !self.isGenerating()) {
                        setTimeout(() => {
                            // 再次检查状态，防止在 reset 后触发
                            if (self.state !== 'generating') return;
                            if (!self.isGenerating()) {
                                self.log("🎯 Button observer detected completion (Stop button disappeared)");
                                self.onGenerationComplete(id);
                            }
                        }, 300);
                    }
                });

                // 观察整个body的变化
                this.buttonObserver.observe(document.body, {
                    childList: true,
                    subtree: true,
                    attributes: true,
                    attributeFilter: ['disabled', 'aria-label', 'class', 'style']
                });

                // 轮询备用（500ms间隔）
                this.pollInterval = setInterval(function() {
                    if (self.state !== 'generating') {
                        clearInterval(self.pollInterval);
                        return;
                    }

                    // 检测 Stop 按钮
                    const stopBtn = document.querySelector(
                        'button[aria-label*="Stop"], button[aria-label*="stop"], ' +
                        'button[data-tooltip*="Stop"], button[title*="Stop"]'
                    );
                    if (stopBtn && stopBtn.offsetParent !== null) {
                        self.stopButtonEverSeen = true;
                    }

                    // 在 grace period 内，不触发完成
                    if (self.inGracePeriod) {
                        return;
                    }

                    // 完成条件：
                    // 1. Stop 按钮曾经出现过，现在消失了
                    // 2. 或者已经过了足够长时间（10秒后），且不在生成状态
                    const elapsed = Date.now() - self.generationStartTime;
                    const canComplete = self.stopButtonEverSeen || elapsed > 10000;

                    if (canComplete && !self.isGenerating()) {
                        setTimeout(() => {
                            if (!self.isGenerating() && self.state === 'generating') {
                                self.log("🎯 Poll detected completion (elapsed: " + elapsed + "ms)");
                                self.onGenerationComplete(id);
                            }
                        }, 500);
                    }

                    // 超时保护（90秒）
                    if (elapsed > 90000) {
                        self.log("⏰ Generation timeout, force completing");
                        self.onGenerationComplete(id);
                    }
                }, 500);

                // 首次检查延迟到 grace period 之后
                setTimeout(() => {
                    if (self.state === 'generating') {
                        // 额外检查：如果 Stop 按钮从未出现，可能页面没有正常响应
                        if (!self.stopButtonEverSeen) {
                            self.log("⚠️ Checking for content despite no Stop button...");
                            const responseEl = self.getResponseElement();
                            if (responseEl && responseEl.innerText.trim().length > 10) {
                                // 有内容，可能生成很快完成了
                                if (!self.isGenerating()) {
                                    self.log("🎯 Found content, completing");
                                    self.onGenerationComplete(id);
                                }
                            }
                        }
                    }
                }, 4000);  // 4秒后检查
            },

            // ===== 生成完成处理 =====
            onGenerationComplete: function(id) {
                // 防止重复触发
                if (this.state !== 'generating') {
                    this.log("⚠️ onGenerationComplete called but state is: " + this.state);
                    return;
                }

                this.state = 'complete';
                this.log("✅ Generation complete, extracting response...");

                // 停止观察者
                if (this.buttonObserver) {
                    this.buttonObserver.disconnect();
                    this.buttonObserver = null;
                }
                if (this.pollInterval) {
                    clearInterval(this.pollInterval);
                    this.pollInterval = null;
                }

                // 提取回复内容
                const responseEl = this.getResponseElement();
                let content = '';

                if (responseEl) {
                    content = responseEl.innerText.trim();
                    this.log("📝 Extracted content length: " + content.length);

                    // 清理可能的 "Thinking..." 前缀
                    if (content.startsWith('Thinking...')) {
                        content = content.substring('Thinking...'.length).trim();
                    }
                    if (content.startsWith('Thinking')) {
                        content = content.substring('Thinking'.length).trim();
                    }
                } else {
                    this.log("⚠️ Could not locate response element");
                }

                // 最终验证
                if (!content || content.length === 0) {
                    this.finish(id, 'Error: Could not extract response content');
                } else if (content === this.lastSentText) {
                    this.finish(id, 'Error: Extracted user prompt instead of response');
                } else {
                    this.finish(id, content);
                }
            },

            // ===== 重置状态 =====
            reset: function() {
                this.log("🔄 Resetting bridge state");

                this.state = 'idle';
                this.currentPromptId = null;
                this.userPromptElement = null;
                this.generationStartTime = null;
                this.inGracePeriod = false;
                this.stopButtonEverSeen = false;

                if (this.buttonObserver) {
                    this.buttonObserver.disconnect();
                    this.buttonObserver = null;
                }
                if (this.pollInterval) {
                    clearInterval(this.pollInterval);
                    this.pollInterval = null;
                }
                if (this.graceTimeout) {
                    clearTimeout(this.graceTimeout);
                    this.graceTimeout = null;
                }
            },

            // ===== 完成并发送结果（带重复检测）=====
            finish: function(id, content) {
                this.log("🏁 Finishing with content length: " + (content ? content.length : 0));

                const now = Date.now();
                const timeSinceLastResponse = now - this.lastResponseTime;

                // ===== 检查是否是重复/陈旧内容 =====
                if (content && content === this.lastResponseContent) {
                    // 相同内容检测
                    if (timeSinceLastResponse < 30000) {  // 30秒内
                        this.log("⚠️ Duplicate content detected (same as last response " +
                                 timeSinceLastResponse + "ms ago)");

                        // 如果还在生成状态，继续等待
                        if (this.state === 'generating' || this.state === 'complete') {
                            this.log("🔄 Waiting for new content...");
                            // 延迟重试提取
                            const self = this;
                            setTimeout(() => {
                                if (self.state !== 'idle') {
                                    const newEl = self.getResponseElement();
                                    const newContent = newEl ? newEl.innerText.trim() : '';
                                    if (newContent && newContent !== self.lastResponseContent) {
                                        self.finishWithContent(id, newContent);
                                    } else {
                                        // 超时后强制返回
                                        self.finishWithContent(id, 'Error: Got duplicate content, UI may not have updated');
                                    }
                                }
                            }, 2000);
                            return;
                        }
                    } else {
                        this.log("ℹ️ Same content but >30s passed, accepting as valid");
                    }
                }

                this.finishWithContent(id, content);
            },

            // ===== 实际发送结果 =====
            finishWithContent: function(id, content) {
                const result = content || 'Error: No content';

                // 记录这次响应（用于下次重复检测）
                if (result && !result.startsWith('Error:')) {
                    this.lastResponseContent = result;
                    this.lastResponseTime = Date.now();
                }

                this.reset();
                this.postToSwift({ type: 'GEMINI_RESPONSE', id: id, content: result });
            },

            // ===== 强制完成（超时调用） =====
            forceFinish: function(id) {
                this.log("⚠️ Force finish called");

                // 尝试提取现有内容
                const responseEl = this.getResponseElement();
                let content = responseEl ? responseEl.innerText.trim() : '';

                if (content && content.length > 0 && content !== this.lastSentText) {
                    this.finish(id, content);
                } else {
                    this.finish(id, 'Error: Timeout - Could not extract response');
                }
            },

            // ===== 登录状态检查 =====
            checkLogin: function() {
                const loggedIn = window.location.href.includes('gemini.google.com') &&
                                 !!document.querySelector('div[contenteditable="true"]');
                this.postToSwift({ type: 'LOGIN_STATUS', loggedIn: loggedIn });
                return loggedIn;
            }
        };

        // 初始化时检查登录状态
        setTimeout(function() {
            window.__fetchBridge.checkLogin();
        }, 2000);

        console.log("✅ Bridge v29 Ready");
    })();
    """
}
