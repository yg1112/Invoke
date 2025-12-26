import Foundation

/// Aider Service v2.0 - Man-in-the-Middle 架构
/// Fetch 充当中间人：User -> Fetch -> Gemini -> Fetch -> Aider
@MainActor
class AiderService: ObservableObject {
    static let shared = AiderService()
    
    @Published var messages: [ChatMessage] = []
    @Published var isThinking = false
    @Published var isRunning = false
    @Published var currentProject: String = ""
    
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    
    struct ChatMessage: Identifiable {
        let id = UUID()
        let content: String
        let isUser: Bool
        let timestamp = Date()
    }
    
    // MARK: - Aider Process Management
    
    func startAider(projectPath: String) {
        guard !isRunning else { return }
        currentProject = projectPath
        
        let process = Process()
        
        // 查找 aider 路径
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
            appendSystemMessage("⚠️ Aider not found. Running in Gemini-only mode.")
            appendSystemMessage("To enable code editing, install: pip install aider-chat")
            isRunning = true // 仍然可以使用 Gemini
            return
        }
        
        process.executableURL = URL(fileURLWithPath: foundPath)
        process.currentDirectoryURL = URL(fileURLWithPath: projectPath)
        
        // 新架构：Aider 不需要连接 API，只接收本地指令
        var env = ProcessInfo.processInfo.environment
        env["AIDER_NO_AUTO_COMMIT"] = "1"  // 我们自己处理 Git
        process.environment = env
        
        // 获取 LocalAPIServer 端口
        let apiPort = LocalAPIServer.shared.port
        
        process.arguments = [
            "--model", "openai/gemini-2.0-flash",  // 模型名无所谓，发给我们自己
            "--openai-api-base", "http://127.0.0.1:\(apiPort)/v1",
            "--openai-api-key", "fetch-local-key", // 骗过校验
            "--no-git",     // 我们自己处理 git
            "--yes",        // 自动应用更改
            "--no-auto-commits"
        ]
        
        let inPipe = Pipe()
        let outPipe = Pipe()
        
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = outPipe
        
        self.inputPipe = inPipe
        self.outputPipe = outPipe
        
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let string = String(data: data, encoding: .utf8), !string.isEmpty {
                DispatchQueue.main.async {
                    self?.handleAiderOutput(string)
                }
            }
        }
        
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.appendSystemMessage("Aider stopped.")
            }
        }
        
        do {
            try process.run()
            self.process = process
            self.isRunning = true
            appendSystemMessage("Aider ready on \(projectPath)")
        } catch {
            appendSystemMessage("Failed to start Aider: \(error.localizedDescription)")
            isRunning = true // 仍然可以使用 Gemini-only 模式
        }
    }
    
    // MARK: - New Man-in-the-Middle Flow
    
    /// 用户发送消息 → Fetch 转发给 Gemini → 获取响应 → 应用代码
    func sendUserMessage(_ text: String) {
        // 1. 显示用户消息
        messages.append(ChatMessage(content: text, isUser: true))
        isThinking = true
        
        // 2. 发送给 Gemini
        let bridgeService = BridgeService.shared
        
        // 构造包含项目上下文的 prompt
        let contextualPrompt = buildContextualPrompt(text)
        
        bridgeService.sendPrompt(contextualPrompt, model: "default") { [weak self] response in
            DispatchQueue.main.async {
                self?.handleGeminiResponse(response)
            }
        }
    }
    
    private func buildContextualPrompt(_ userMessage: String) -> String {
        // 添加代码编辑上下文
        return """
        You are an AI coding assistant. The user is working on project: \(currentProject)
        
        IMPORTANT: When providing code changes, use this exact format:
        
        ```filepath:path/to/file.ext
        // full file content here
        ```
        
        User request: \(userMessage)
        """
    }
    
    private func handleGeminiResponse(_ response: String) {
        isThinking = false
        
        // 显示 AI 响应
        messages.append(ChatMessage(content: response, isUser: false))
        
        // 提取代码块并应用
        let codeBlocks = extractCodeBlocks(from: response)
        
        if !codeBlocks.isEmpty {
            applyCodeChanges(codeBlocks)
        }
    }
    
    // MARK: - Code Extraction & Application
    
    private struct CodeBlock {
        let filePath: String
        let content: String
    }
    
    private func extractCodeBlocks(from text: String) -> [CodeBlock] {
        var blocks: [CodeBlock] = []
        
        // 匹配 ```filepath:path/to/file.ext 格式
        let pattern = "```(?:filepath:)?([^\\n`]+)\\n([\\s\\S]*?)```"
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return blocks
        }
        
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        
        for match in matches {
            guard let pathRange = Range(match.range(at: 1), in: text),
                  let contentRange = Range(match.range(at: 2), in: text) else { continue }
            
            let path = String(text[pathRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let content = String(text[contentRange])
            
            // 跳过语言标识符 (如 swift, python 等)
            if path.contains("/") || path.contains(".") {
                blocks.append(CodeBlock(filePath: path, content: content))
            }
        }
        
        return blocks
    }
    
    private func applyCodeChanges(_ blocks: [CodeBlock]) {
        for block in blocks {
            let fullPath = URL(fileURLWithPath: currentProject).appendingPathComponent(block.filePath)
            
            do {
                // 确保目录存在
                try FileManager.default.createDirectory(
                    at: fullPath.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                
                // 写入文件
                try block.content.write(to: fullPath, atomically: true, encoding: .utf8)
                
                appendSystemMessage("✅ Updated: \(block.filePath)")
                
            } catch {
                appendSystemMessage("❌ Failed to write \(block.filePath): \(error.localizedDescription)")
            }
        }
        
        // 自动 Git 提交
        if !blocks.isEmpty {
            let fileNames = blocks.map { URL(fileURLWithPath: $0.filePath).lastPathComponent }.joined(separator: ", ")
            GitService.shared.autoPushChanges(in: currentProject, message: "feat: Update \(fileNames) via Fetch")
        }
    }
    
    // MARK: - Aider Direct Commands (Optional)
    
    /// 直接发送命令给 Aider (用于高级操作)
    func sendAiderCommand(_ text: String) {
        guard let data = (text + "\n").data(using: .utf8),
              let pipe = inputPipe else { return }
        
        do {
            try pipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            appendSystemMessage("Failed to send to Aider: \(error.localizedDescription)")
        }
    }
    
    private func handleAiderOutput(_ text: String) {
        let cleanText = text.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*[mK]",
            with: "",
            options: .regularExpression
        )
        
        // Aider 输出可以合并显示
        if let lastMsg = messages.last, !lastMsg.isUser, lastMsg.content.hasPrefix("[Aider]") {
            let newContent = lastMsg.content + cleanText
            messages[messages.count - 1] = ChatMessage(content: newContent, isUser: false)
        } else if !cleanText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(ChatMessage(content: "[Aider] " + cleanText, isUser: false))
        }
        
        // 检测完成状态
        if text.contains("> ") {
            isThinking = false
        }
    }
    
    // MARK: - Helpers
    
    private func appendSystemMessage(_ text: String) {
        messages.append(ChatMessage(content: "🔧 " + text, isUser: false))
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
