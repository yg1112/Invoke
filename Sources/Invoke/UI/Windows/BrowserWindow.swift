import SwiftUI
import WebKit
import AppKit

/// 浏览器登录窗口 - 提供多种登录方式
class BrowserWindowController: NSObject, ObservableObject {
    static let shared = BrowserWindowController()
    
    private var window: NSWindow?
    @Published var isShowing = false
    
    func showLoginWindow() {
        // 🔑 核心修复：强制将 App 升级为 Regular 模式以接收键盘事件
        NSApp.setActivationPolicy(.regular)
        
        guard window == nil else {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let hostingView = NSHostingView(rootView: LoginMethodsView(
            onClose: { [weak self] in
                self?.hideWindow()
            },
            onLoginSuccess: { [weak self] in
                self?.onLoginSuccess()
            }
        ))
        
        let newWindow = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        
        newWindow.title = "Login to Gemini - Fetch"
        newWindow.contentView = hostingView
        newWindow.center()
        newWindow.delegate = self
        newWindow.level = .floating
        newWindow.hidesOnDeactivate = false
        newWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        self.window = newWindow
        self.isShowing = true
        
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    private func onLoginSuccess() {
        print("✅ Login success detected in BrowserWindowController")
        
        // 延迟更长时间再关闭，确保 WebView 完成所有导航
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.hideWindow()
            // 刷新主 WebView
            GeminiWebManager.shared.loadGemini()
        }
        
        NotificationCenter.default.post(name: .loginSuccess, object: nil)
    }
    
    func hideWindow() {
        // 先停止所有 WebView 加载
        if window?.contentView is NSHostingView<LoginMethodsView> {
            // 窗口会在关闭时自动清理 WebView
        }
        
        window?.close()
        window = nil
        isShowing = false
        // 窗口关闭后，变回菜单栏应用模式
        NSApp.setActivationPolicy(.accessory)
    }
}

extension BrowserWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        window = nil
        isShowing = false
        // 窗口关闭后，变回菜单栏应用模式（隐藏 Dock 图标）
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - 可接收键盘输入的窗口
class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }
}

// MARK: - 登录方式选择界面

struct LoginMethodsView: View {
    let onClose: () -> Void
    let onLoginSuccess: () -> Void
    
    @State private var showCookieInput = false
    @State private var showWebView = false
    @State private var cookieText: String = ""
    @State private var isInjecting = false
    @State private var statusMessage = ""
    
    let neonGreen = Color(red: 0.0, green: 0.9, blue: 0.5)
    
    var body: some View {
            VStack(spacing: 0) {
            // Header
                    HStack {
                Image(systemName: "sparkles")
                    .font(.system(size: 28))
                            .foregroundColor(.blue)
                        
                        VStack(alignment: .leading, spacing: 2) {
                    Text("Connect to Gemini")
                        .font(.title2.bold())
                    Text("Choose a login method")
                                .font(.caption)
                        .foregroundColor(.secondary)
                        }
                        
                        Spacer()
            }
            .padding(20)
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            ScrollView {
                VStack(spacing: 16) {
                    // 方法 1: Cookie 登录 (推荐)
                    LoginMethodCard(
                        icon: "🍪",
                        title: "Cookie 登录",
                        subtitle: "推荐 · 100% 成功率",
                        description: "从 Chrome 控制台复制 Cookie",
                        isExpanded: $showCookieInput,
                        accentColor: neonGreen
                    ) {
                        CookieInputView(
                            cookieText: $cookieText,
                            isInjecting: $isInjecting,
                            statusMessage: $statusMessage,
                            onSuccess: onLoginSuccess
                        )
                    }
                    
                    // 方法 2: 网页登录 (有键盘问题)
                    LoginMethodCard(
                        icon: "🌐",
                        title: "网页登录",
                        subtitle: "⚠️ 键盘输入可能有问题",
                        description: "在内置浏览器中登录 Google",
                        isExpanded: $showWebView,
                        accentColor: .blue
                    ) {
                        VStack(spacing: 12) {
                            Text("已知问题：部分系统上键盘无法输入")
                                .font(.caption)
                                .foregroundColor(.orange)
                            
                            Button("打开登录页面") {
                                openWebLoginWindow()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding()
                    }
                    
                    // 方法 3: 打开外部浏览器
                    HStack {
                        Image(systemName: "safari")
                            .font(.system(size: 20))
                            .foregroundColor(.gray)
                        
                        VStack(alignment: .leading) {
                            Text("在系统浏览器中打开")
                                .font(.subheadline)
                            Text("登录后使用 Cookie 方法导入")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        Button("打开") {
                            if let url = URL(string: "https://gemini.google.com") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .cornerRadius(12)
                }
                .padding(20)
            }
        }
    }
    
    private func openWebLoginWindow() {
        // 🔑 确保 App 为 Regular 模式以接收键盘
        NSApp.setActivationPolicy(.regular)
        
        // 打开一个独立的 WebView 窗口
        let webWindow = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        webWindow.title = "Google Login - Fetch"
        webWindow.contentView = NSHostingView(rootView: WebLoginView(onSuccess: onLoginSuccess))
        webWindow.center()
        webWindow.level = .floating
        webWindow.hidesOnDeactivate = false
        webWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        webWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - 登录方法卡片

struct LoginMethodCard<Content: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    let description: String
    @Binding var isExpanded: Bool
    let accentColor: Color
    @ViewBuilder let content: () -> Content
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            Button(action: { withAnimation(.spring(response: 0.3)) { isExpanded.toggle() } }) {
                HStack {
                    Text(icon)
                        .font(.system(size: 28))
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.headline)
                            .foregroundColor(.primary)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(accentColor)
                    }
                    
                    Spacer()
                    
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
            }
            .buttonStyle(.plain)
            
            // Expanded content
            if isExpanded {
                Divider()
                content()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isExpanded ? accentColor.opacity(0.5) : Color.clear, lineWidth: 2)
        )
    }
}

// MARK: - Cookie 输入视图

struct CookieInputView: View {
    @Binding var cookieText: String
    @Binding var isInjecting: Bool
    @Binding var statusMessage: String
    let onSuccess: () -> Void
    
    let neonGreen = Color(red: 0.0, green: 0.9, blue: 0.5)
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 步骤说明
            VStack(alignment: .leading, spacing: 8) {
                StepRow(number: 1, text: "在 Chrome 打开 gemini.google.com 并登录")
                StepRow(number: 2, text: "按 F12 (或 Cmd+Option+J) 打开控制台")
                StepRow(number: 3, text: "输入 document.cookie 并回车")
                StepRow(number: 4, text: "复制那串红色字符（去掉引号）")
            }
            
            // 输入框
            TextEditor(text: $cookieText)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 80)
                .padding(8)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
            
            // 状态消息
            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundColor(statusMessage.contains("✅") ? neonGreen : .orange)
            }
            
            // 按钮
            HStack {
                Spacer()
                
                Button(action: injectCookies) {
                    HStack {
                        if isInjecting {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.8)
                        }
                        Text(isInjecting ? "注入中..." : "🚀 登录")
                    }
                    .frame(minWidth: 100)
                }
                .buttonStyle(.borderedProminent)
                .tint(neonGreen)
                .disabled(cookieText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isInjecting)
            }
        }
        .padding()
    }
    
    private func injectCookies() {
        guard !cookieText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        isInjecting = true
        statusMessage = "正在注入 Cookie..."
        
        GeminiWebManager.shared.injectRawCookies(cookieText) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                isInjecting = false
                GeminiWebManager.shared.checkLoginStatus()
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    if GeminiWebManager.shared.isLoggedIn {
                        statusMessage = "✅ 登录成功！"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            onSuccess()
                        }
                    } else {
                        statusMessage = "⚠️ Cookie 可能无效，请确保复制完整"
                    }
                }
            }
        }
    }
}

// MARK: - Web 登录视图 (备用)

struct WebLoginView: View {
    let onSuccess: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("⚠️ 如果无法输入，请使用 Cookie 方式登录")
                    .font(.caption)
                    .foregroundColor(.orange)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.1))
            
            EphemeralLoginWebView(onLoginSuccess: onSuccess)
        }
    }
}

// MARK: - 专用登录 WebView

struct EphemeralLoginWebView: NSViewRepresentable {
    let onLoginSuccess: () -> Void
    
    // 🔑 Safari 策略：使用真实的 Safari UA，与 WKWebView 内核完全匹配
    private let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/605.1.15"
    
    // Safari 精简版伪装脚本 - 只移除 webdriver 标记
    private static let safariStealthScript = """
    (function() {
        'use strict';
        // 移除 WebDriver 标记 (核心)
        Object.defineProperty(navigator, 'webdriver', { 
            get: () => undefined,
            configurable: true
        });
        delete navigator.webdriver;
        
        // 保持 Safari 原生的 languages
        Object.defineProperty(navigator, 'languages', { 
            get: () => ['en-US', 'en'],
            configurable: true
        });
    })();
    """
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onLoginSuccess: onLoginSuccess)
    }
    
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        // 重要：不设置 applicationNameForUserAgent，避免附加额外信息
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        
        // 🔑 注入精简版伪装脚本（Safari 策略）
        let stealthScript = WKUserScript(
            source: Self.safariStealthScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(stealthScript)
        
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        webView.customUserAgent = safariUserAgent
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        
        // 使用 accounts.google.com 登录
        let loginURL = URL(string: "https://accounts.google.com/ServiceLogin?continue=https://gemini.google.com/app")!
        webView.load(URLRequest(url: loginURL))
        
        return webView
    }
    
    func updateNSView(_ nsView: WKWebView, context: Context) {}
    
    class Coordinator: NSObject, WKNavigationDelegate {
        let onLoginSuccess: () -> Void
        private var hasTriggeredSuccess = false
        
        init(onLoginSuccess: @escaping () -> Void) {
            self.onLoginSuccess = onLoginSuccess
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let url = webView.url?.absoluteString else { return }
            print("📍 Navigation finished: \(url)")
            
            // 检测是否已到达 Gemini 主页面（登录成功）
            if url.contains("gemini.google.com") && !url.contains("signin") && !url.contains("accounts.google") && !hasTriggeredSuccess {
                hasTriggeredSuccess = true
                print("✅ Login detected. Initiating safe teardown...")
                
                // 播放成功音效
                NSSound(named: "Glass")?.play()
                
                // 🔑 安全销毁协议 (Safe Teardown Protocol)
                // 1. 强制停止加载 (防止后续的导航回调)
                webView.stopLoading()
                
                // 2. [关键修复] 切断代理联系
                // 这能防止崩溃堆栈中的 WebFramePolicyListenerProxy 错误
                webView.navigationDelegate = nil
                webView.uiDelegate = nil
                
                // 3. 延迟一小会儿让 WebKit 线程完成当前循环
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    // 4. 通知上层关闭窗口
                    self?.onLoginSuccess()
                }
            }
        }
        
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // 如果已经触发了成功逻辑，直接取消后续请求，防止崩溃
            if hasTriggeredSuccess {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("❌ Navigation failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let loginSuccess = Notification.Name("FetchLoginSuccess")
}
