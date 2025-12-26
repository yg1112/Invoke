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
    
    /// 智能查找 Aider 路径（优先级：配置文件 > 动态查找 > 硬编码路径）
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
        
        // 2. 使用 shell 动态查找（通过 which 命令）
        let whichProcess = Process()
        whichProcess.executableURL = URL(fileURLWithPath: "/bin/bash")
        whichProcess.arguments = ["-c", "which aider"]
        
        let whichPipe = Pipe()
        whichProcess.standardOutput = whichPipe
        whichProcess.standardError = Pipe()
        
        do {
            try whichProcess.run()
            whichProcess.waitUntilExit()
            
            let data = whichPipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !output.isEmpty,
               FileManager.default.fileExists(atPath: output) {
                return output
            }
        } catch {
            // 继续尝试其他方法
        }
        
        // 3. 扩展的硬编码路径列表（包括常见 Python 环境）
        let homeDir = NSHomeDirectory()
        let possiblePaths = [
            "/usr/local/bin/aider",
            "/opt/homebrew/bin/aider",
            "\(homeDir)/.local/bin/aider",
            "\(homeDir)/anaconda3/bin/aider",
            "\(homeDir)/miniconda3/bin/aider",
            "\(homeDir)/.pyenv/shims/aider",
            "\(homeDir)/.pyenv/versions/*/bin/aider",
            "/opt/anaconda3/bin/aider",
            "/usr/bin/aider"
        ]
        
        for path in possiblePaths {
            // 处理通配符路径
            if path.contains("*") {
                let dir = (path as NSString).deletingLastPathComponent
                let pattern = (path as NSString).lastPathComponent
                if let enumerator = FileManager.default.enumerator(atPath: dir) {
                    for file in enumerator {
                        if let fileName = file as? String, fileName == "aider" {
                            let fullPath = (dir as NSString).appendingPathComponent(fileName)
                            if FileManager.default.fileExists(atPath: fullPath) {
                                return fullPath
                            }
                        }
                    }
                }
            } else if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        
        return nil
    }
    
    func startAider(projectPath: String) {
        guard !isRunning else { return }
        currentProject = projectPath
        
        let process = Process()
        
        // 智能查找 aider 路径
        guard let foundPath = findAiderPath() else {
            appendSystemMessage("⚠️ Aider not found. Running in Gemini-only mode.")
            appendSystemMessage("💡 Run: ./Setup_Aider_Path.sh to auto-configure")
            appendSystemMessage("Or install: pip install aider-chat")
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
            "--no-auto-commits",
            "--no-show-model-warnings"  // 禁止模型警告，避免打开网页和卡在确认界面
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
