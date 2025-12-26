import Foundation
import Combine

/// Aider Service v3.0 - Robust Process Wrapper
/// 架构：User Input -> Aider Process (stdin) -> Local API -> Gemini -> Aider -> Fetch UI (stdout)
@MainActor
class AiderService: ObservableObject {
    static let shared = AiderService()
    
    @Published var messages: [ChatMessage] = []
    @Published var isThinking = false
    @Published var isRunning = false
    @Published var currentProject: String = ""
    @Published var initializationStatus: String = "Ready"
    
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    
    struct ChatMessage: Identifiable, Equatable {
        let id = UUID()
        let content: String
        let isUser: Bool
        let timestamp = Date()
    }
    
    // MARK: - Aider Process Management
    
    /// 智能查找 Aider 路径
    private func findAiderPath() -> String? {
        // 1. 优先从配置文件读取
        let configDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.yukungao.fetch")
        let configFile = configDir?.appendingPathComponent("config.json")
        
        if let configFile = configFile,
           let data = try? Data(contentsOf: configFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let path = json["aiderPath"] as? String,
           FileManager.default.fileExists(atPath: path) {
            return path
        }
        
        // 2. 使用 shell 动态查找
        let whichProcess = Process()
        whichProcess.executableURL = URL(fileURLWithPath: "/bin/bash")
        whichProcess.arguments = ["-c", "which aider"]
        let whichPipe = Pipe()
        whichProcess.standardOutput = whichPipe
        
        try? whichProcess.run()
        whichProcess.waitUntilExit()
        
        let data = whichPipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !output.isEmpty, FileManager.default.fileExists(atPath: output) {
            return output
        }
        
        // 3. 常见路径回退
        let home = NSHomeDirectory()
        let paths = [
            "/usr/local/bin/aider",
            "/opt/homebrew/bin/aider",
            "\(home)/.local/bin/aider",
            "/usr/bin/aider",
            "\(home)/anaconda3/bin/aider"
        ]
        
        for path in paths {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        
        return nil
    }
    
    func startAider(projectPath: String) {
        stop() // 确保之前的进程已清理
        
        currentProject = projectPath
        initializationStatus = "Starting Local API..."
        
        // 1. 确保 API Server 已启动 (关键修复)
        LocalAPIServer.shared.start()
        let apiPort = LocalAPIServer.shared.port
        
        guard let aiderPath = findAiderPath() else {
            appendSystemMessage("❌ Aider executable not found.")
            appendSystemMessage("💡 Please install aider: pip install aider-chat")
            return
        }
        
        initializationStatus = "Launching Aider..."
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: aiderPath)
        process.currentDirectoryURL = URL(fileURLWithPath: projectPath)
        
        // 环境配置
        var env = ProcessInfo.processInfo.environment
        env["AIDER_NO_AUTO_COMMIT"] = "1" // 防止自动 Commit，由用户控制
        env["TERM"] = "xterm-256color"    // 确保颜色输出正确
        env["PYTHONIOENCODING"] = "utf-8"
        process.environment = env
        
        // 参数配置：连接到我们的 Local API
        process.arguments = [
            "--model", "openai/gemini-2.0-flash", // 指向我们的本地代理模型
            "--openai-api-base", "http://127.0.0.1:\(apiPort)/v1",
            "--openai-api-key", "sk-dummy-key",   // 任意 Key
            "--no-git",       // 我们自己处理 git 或由用户手动处理
            "--yes",          // 自动确认
            "--no-show-model-warnings",
            "--dark-mode"     // 强制暗色模式适配 UI
        ]
        
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe() // 分离 stderr (关键修复：防止死锁)
        
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
        
        self.inputPipe = inPipe
        self.outputPipe = outPipe
        self.errorPipe = errPipe
        
        // 处理标准输出
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let str = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    self?.handleAiderOutput(str)
                }
            }
        }
        
        // 处理错误输出 (记录日志但不直接显示在聊天气泡中，除非是致命错误)
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                print("[Aider Error] \(str)")
            }
        }
        
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.isThinking = false
                self?.initializationStatus = "Stopped"
                self?.appendSystemMessage("Aider process terminated.")
            }
        }
        
        do {
            try process.run()
            self.process = process
            self.isRunning = true
            self.initializationStatus = "Running"
            appendSystemMessage("🚀 Aider connected on \(projectPath)")
        } catch {
            appendSystemMessage("❌ Failed to launch: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Messaging
    
    /// 发送消息给 Aider 进程
    func sendUserMessage(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        // 1. UI 立即显示
        messages.append(ChatMessage(content: text, isUser: true))
        isThinking = true
        
        // 2. 写入管道 (核心修复：不再绕过 Aider)
        if let pipe = inputPipe, isRunning {
            let cleanText = text.replacingOccurrences(of: "\n", with: " ") // 单行发送避免多行问题
            if let data = "\(cleanText)\n".data(using: .utf8) {
                try? pipe.fileHandleForWriting.write(contentsOf: data)
            }
        } else {
            appendSystemMessage("⚠️ Aider is not running. Please restart the session.")
            isThinking = false
        }
    }
    
    /// 处理 Aider 的输出流
    private func handleAiderOutput(_ text: String) {
        // 清理 ANSI 转义序列 (颜色代码)
        let cleanText = text.replacingOccurrences(
            of: "\\x1B(?:\\[[0-9;]*[mK]?)",
            with: "",
            options: .regularExpression
        )
        
        guard !cleanText.isEmpty else { return }
        
        // 简单的状态机：检测是否在等待输入
        if cleanText.contains("> ") || cleanText.contains("? ") {
            isThinking = false
        } else {
            // 如果收到大量文本，可能正在生成
            isThinking = true
        }
        
        // 合并连续的 Aider 消息，避免刷屏
        if var lastMsg = messages.last, !lastMsg.isUser {
            // 如果上一条也是 Aider 的消息，追加内容
            let newContent = lastMsg.content + cleanText
            messages[messages.count - 1] = ChatMessage(content: newContent, isUser: false)
        } else {
            // 新消息
            messages.append(ChatMessage(content: cleanText, isUser: false))
        }
    }
    
    // MARK: - Lifecycle
    
    func stop() {
        // 清理 Handler 防止内存泄漏和崩溃
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        
        process?.terminate()
        process = nil
        isRunning = false
        isThinking = false
        
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
    }
    
    private func appendSystemMessage(_ text: String) {
        messages.append(ChatMessage(content: text, isUser: false))
    }
    
    func clearMessages() {
        messages.removeAll()
    }
}