import Foundation
import Combine

/// Bridge Service v2.0 - Native WKWebView 实现
/// 不再需要 Python proxy，直接使用 GeminiWebManager
@MainActor
class BridgeService: ObservableObject {
    static let shared = BridgeService()
    
    @Published var isRunning = false
    @Published var connectionStatus = "Initializing..."
    @Published var isLoggedIn = false
    
    private var cancellables = Set<AnyCancellable>()
    private let webManager = GeminiWebManager.shared
    
    private init() {
        setupBindings()
    }
    
    private func setupBindings() {
        // 订阅 WebManager 状态
        webManager.$connectionStatus
            .receive(on: DispatchQueue.main)
            .assign(to: &$connectionStatus)
        
        webManager.$isLoggedIn
            .receive(on: DispatchQueue.main)
            .assign(to: &$isLoggedIn)
        
        webManager.$isReady
            .receive(on: DispatchQueue.main)
            .assign(to: &$isRunning)
    }
    
    // MARK: - Public API
    
    /// 启动 Bridge (初始化 WebView)
    func startBridge() {
        connectionStatus = "Starting Native Bridge..."
        webManager.loadGemini()
    }
    
    /// 停止 Bridge
    func stopBridge() {
        isRunning = false
        connectionStatus = "Stopped"
    }
    
    /// 显示登录窗口 (使用纯 AppKit 控制器，避免 SwiftUI 生命周期导致的 WebKit 崩溃)
    func showLoginWindow() {
        LoginWindowController.shared.show()
    }
    
    /// 发送 Prompt 到 Gemini
    func sendPrompt(_ text: String, model: String = "default", completion: @escaping (String) -> Void) {
        guard isLoggedIn else {
            showLoginWindow()
            completion("Error: Please login to Google first")
            return
        }
        
        webManager.sendPrompt(text, model: model, completion: completion)
    }
    
    /// 检查健康状态
    func checkHealth() {
        webManager.checkLoginStatus()
    }
}
