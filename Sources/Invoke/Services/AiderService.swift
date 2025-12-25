import Foundation

class AiderService: ObservableObject {
    static let shared = AiderService()
    
    @Published var messages: [ChatMessage] = []
    @Published var isThinking = false
    @Published var isRunning = false
    
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    
    struct ChatMessage: Identifiable {
        let id = UUID()
        let content: String
        let isUser: Bool
        let timestamp = Date()
    }

    func startAider(projectPath: String) {
        guard !isRunning else { return }
        
        let process = Process()
        
        // 尝试查找 aider 路径
        let possiblePaths = [
            "/usr/local/bin/aider",
            "/opt/homebrew/bin/aider",
            "\(NSHomeDirectory())/.local/bin/aider"
        ]
        
        var aiderPath: String?
        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                aiderPath = path
                break
            }
        }
        
        guard let foundPath = aiderPath else {
            appendOutput("System: Aider not found. Please install: pip install aider-chat")
            return
        }
        
        process.executableURL = URL(fileURLWithPath: foundPath)
        process.currentDirectoryURL = URL(fileURLWithPath: projectPath)
        
        // 关键配置：指向我们的 Bridge
        var env = ProcessInfo.processInfo.environment
        env["OPENAI_API_BASE"] = "http://localhost:3000/v1"
        env["OPENAI_API_KEY"] = "dummy" // Aider 需要任意非空 key
        process.environment = env
        
        process.arguments = [
            "--model", "openai/gemini-web",
            "--no-git",  // 我们自己处理 git
            "--yes"      // 自动应用更改
        ]
        
        let inPipe = Pipe()
        let outPipe = Pipe()
        
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = outPipe // 合并错误输出以便调试
        
        self.inputPipe = inPipe
        self.outputPipe = outPipe
        
        // 实时读取输出
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let string = String(data: data, encoding: .utf8), !string.isEmpty {
                DispatchQueue.main.async {
                    self?.appendOutput(string)
                }
            }
        }
        
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.appendOutput("System: Aider stopped.")
            }
        }
        
        do {
            try process.run()
            self.process = process
            self.isRunning = true
            appendOutput("System: Aider started on \(projectPath)")
        } catch {
            appendOutput("System: Failed to launch Aider - \(error)")
        }
    }
    
    func sendCommand(_ text: String) {
        guard let data = (text + "\n").data(using: .utf8),
              let pipe = inputPipe else { return }
        
        // UI 上显示用户发送的消息
        messages.append(ChatMessage(content: text, isUser: true))
        isThinking = true
        
        do {
            try pipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            appendOutput("System: Failed to send command - \(error)")
        }
    }
    
    private func appendOutput(_ text: String) {
        // 简单的流式输出处理 - 去除 ANSI 颜色码
        let cleanText = text.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*[mK]",
            with: "",
            options: .regularExpression
        )
        
        if let lastMsg = messages.last, !lastMsg.isUser {
            // 追加到最后一条 AI 消息
            let newContent = lastMsg.content + cleanText
            messages[messages.count - 1] = ChatMessage(content: newContent, isUser: false)
        } else {
            // 新起一条 AI 消息
            messages.append(ChatMessage(content: cleanText, isUser: false))
        }
        
        // 如果检测到特定的结束符，设置 isThinking = false
        if text.contains("> ") { // Aider 的默认提示符
            isThinking = false
        }
        
        // 如果检测到 Aider 完成了任务，触发自动 Git Push
        if text.contains("Committing") || text.contains("Applied") {
            triggerAutoPush()
        }
    }
    
    private func triggerAutoPush() {
        // 延迟一下确保文件写完
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if let projectPath = self.process?.currentDirectoryURL?.path {
                GitService.shared.autoPushChanges(in: projectPath)
            }
        }
    }
    
    func stop() {
        process?.terminate()
        process = nil
        isRunning = false
        inputPipe = nil
        outputPipe = nil
    }
    
    func clearMessages() {
        messages.removeAll()
    }
}

