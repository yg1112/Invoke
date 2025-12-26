import Cocoa
import WebKit

class LoginPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

class LoginWindowController: NSWindowController, WKNavigationDelegate, NSWindowDelegate {
    static let shared = LoginWindowController()
    
    private var webView: WKWebView!
    private var hasTriggeredSuccess = false
    
    // 直接导航到 Google 登录，然后跳转到 Gemini
    // 流程：Google 登录 -> 直接跳转 Gemini
    private let loginEntryURL = URL(string: "https://accounts.google.com/ServiceLogin?continue=https://gemini.google.com/app")!
    
    init() {
        let panel = LoginPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), // 稍微大一点
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.title = "Sign in with Google"
        panel.center()
        panel.level = .floating 
        panel.isFloatingPanel = true
        
        super.init(window: panel)
        setupWebView()
        panel.delegate = self
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.applicationNameForUserAgent = "Safari"
        config.websiteDataStore = WKWebsiteDataStore.default()
        
        // 注入极简伪装 (与 Manager 保持一致)
        let stealthScript = WKUserScript(
            source: GeminiWebManager.fingerprintMaskScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(stealthScript)
        
        self.webView = WKWebView(frame: .zero, configuration: config)
        self.webView.navigationDelegate = self
        // 关键：必须与 Manager 使用完全相同的 UA
        self.webView.customUserAgent = GeminiWebManager.userAgent
        self.webView.allowsBackForwardNavigationGestures = true
        
        // Auto Layout
        let containerView = NSView()
        self.window?.contentView = containerView
        webView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(webView)
        
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: containerView.topAnchor),
            webView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor)
        ])
    }
    
    func show() {
        self.hasTriggeredSuccess = false
        
        // 1. 复活机制
        if webView.superview == nil, let container = self.window?.contentView {
            container.addSubview(webView)
            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: container.topAnchor),
                webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: container.trailingAnchor)
            ])
        }
        webView.navigationDelegate = self
        
        // 2. 清理脏数据 (关键步骤)
        // 每次打开登录窗口时，清理所有非持久化数据，给 Google 一个全新的环境
        let dataStore = WKWebsiteDataStore.default()
        dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: Date(timeIntervalSince1970: 0)) { [weak self] in
            print("🧹 Cache cleared. Starting fresh login flow.")
            self?.startLoginFlow()
        }
        
        NSApp.activate(ignoringOtherApps: true)
        self.showWindow(nil)
    }
    
    private func startLoginFlow() {
        // 直接加载 Google 登录页面，登录后自动跳转到 Gemini
        webView.load(URLRequest(url: loginEntryURL))
    }
    
    // MARK: - Navigation Logic
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let urlStr = navigationAction.request.url?.absoluteString else {
            decisionHandler(.allow)
            return
        }
        
        print("🔗 Navigating: \(urlStr)")
        
        // 1. 最终目标检测：到达 Gemini（登录成功后 Google 会自动跳转）
        if urlStr.contains("gemini.google.com/app") && !urlStr.contains("accounts.google") {
            decisionHandler(.cancel)
            DispatchQueue.main.async { [weak self] in
                self?.handleLoginSuccess()
            }
            return
        }
        
        decisionHandler(.allow)
    }
    
    private func handleLoginSuccess() {
        guard !hasTriggeredSuccess else { return }
        hasTriggeredSuccess = true
        
        print("🎉 Gemini Connected!")
        NSSound(named: "Glass")?.play()
        
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.removeFromSuperview()
        self.close()
        
        NotificationCenter.default.post(name: .loginSuccess, object: nil)
        
        // 让后台 Manager 刷新状态
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            GeminiWebManager.shared.loadGemini()
        }
    }
}

// Notification name moved to BrowserWindow.swift for consistency
