import Foundation
import Combine

/// Aider Service v3.3 - Stable Pipe & Throttled UI & Full Config Support
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
    
    // UI 节流器
    private let uiThrottler = Throttler(minimumDelay: 0.1)
    private var pendingOutputBuffer = ""
    
    struct ChatMessage: Identifiable, Equatable {
        let id = UUID()
        let content: String
        let isUser: Bool
        let timestamp = Date()
    }
    
    // MARK: - Aider Process Management
    
    /// 完整的路径查找逻辑 (Config > pyenv > Shell > Common Paths)
    private func findAiderPath() -> String? {
        let home = NSHomeDirectory()

        // 1. 优先从配置文件读取
        let configDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.yukungao.fetch")
        let configFile = configDir?.appendingPathComponent("config.json")

        if let configFile = configFile,
           let data = try? Data(contentsOf: configFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let path = json["aiderPath"] as? String,
           !path.contains("/shims/"),  // 跳过 pyenv shims
           FileManager.default.fileExists(atPath: path) {
            print("📍 Aider found in config: \(path)")
            return path
        }

        // 2. 使用 pyenv which aider 获取真实路径
        let pyenvProcess = Process()
        pyenvProcess.executableURL = URL(fileURLWithPath: "/bin/bash")
        pyenvProcess.arguments = ["-l", "-c", "pyenv which aider 2>/dev/null || which aider 2>/dev/null"]
        let pyenvPipe = Pipe()
        pyenvProcess.standardOutput = pyenvPipe
        pyenvProcess.standardError = Pipe() // 避免错误输出污染
        try? pyenvProcess.run()
        pyenvProcess.waitUntilExit()

        let data = pyenvPipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !output.isEmpty,
           !output.contains("/shims/"),  // 确保不是 shim
           FileManager.default.fileExists(atPath: output) {
            print("📍 Aider found via pyenv/which: \(output)")
            return output
        }

        // 3. 常见路径回退（包括 pyenv 版本目录）
        var paths = [
            "/usr/local/bin/aider",
            "/opt/homebrew/bin/aider",
            "\(home)/.local/bin/aider",
            "/usr/bin/aider",
            "\(home)/anaconda3/bin/aider",
            "\(home)/miniconda3/bin/aider"
        ]

        // 添加 pyenv 版本目录
        let pyenvVersionsDir = "\(home)/.pyenv/versions"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: pyenvVersionsDir) {
            for version in versions {
                paths.append("\(pyenvVersionsDir)/\(version)/bin/aider")
            }
        }

        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                print("📍 Aider found at: \(path)")
                return path
            }
        }

        print("❌ Aider not found in any location")
        return nil
    }
    
    func startAider(projectPath: String) {
        // 防止重复启动：如果已经在运行且路径相同，跳过
        if isRunning && currentProject == projectPath {
            print("⏭️ Aider already running on \(projectPath), skipping...")
            return
        }

        stop()

        currentProject = projectPath
        initializationStatus = "Starting Local API..."

        // 确保 API Server 启动
        LocalAPIServer.shared.start()

        guard let aiderPath = findAiderPath() else {
            appendSystemMessage("❌ Aider executable not found. Please install: pip install aider-chat")
            return
        }

        initializationStatus = "Launching Aider..."
        print("🚀 Launching Aider from: \(aiderPath)")

        let process = Process()

        // 使用 bash 来执行 aider（因为 aider 是 Python 脚本）
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.currentDirectoryURL = URL(fileURLWithPath: projectPath)

        var env = ProcessInfo.processInfo.environment
        env["AIDER_NO_AUTO_COMMIT"] = "1"
        env["TERM"] = "xterm-256color"
        env["PYTHONIOENCODING"] = "utf-8"
        // 确保 pyenv 路径在 PATH 中
        let home = NSHomeDirectory()
        env["PATH"] = "\(home)/.pyenv/versions/3.10.13/bin:\(home)/.pyenv/shims:/usr/local/bin:/usr/bin:/bin:\(env["PATH"] ?? "")"
        process.environment = env

        // 构建完整的 aider 命令
        // --no-pretty: 禁用彩色输出和进度条（非TTY模式必需）
        // --no-fancy-input: 禁用花式输入处理（非TTY模式必需）
        let aiderArgs = [
            aiderPath,
            "--model", "openai/gemini-2.0-flash",
            "--openai-api-base", "http://127.0.0.1:\(LocalAPIServer.shared.port)/v1",
            "--openai-api-key", "sk-dummy-key",
            "--no-git",
            "--yes",
            "--no-show-model-warnings",
            "--no-pretty",
            "--no-fancy-input"
        ].joined(separator: " ")

        process.arguments = ["-c", aiderArgs]
        
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe() // 分离管道
        
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
        
        self.inputPipe = inPipe
        self.outputPipe = outPipe
        self.errorPipe = errPipe
        
        // Stdout -> Throttled UI
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self = self else { return }
            if let str = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    self.pendingOutputBuffer += str
                    self.uiThrottler.throttle {
                        self.flushOutputBuffer()
                    }
                }
            }
        }
        
        // Stderr -> Log (启用调试)
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                print("[Aider stderr] \(str)")
            }
        }
        
        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.isThinking = false
                self?.initializationStatus = "Stopped"
                let exitCode = proc.terminationStatus
                self?.appendSystemMessage("Aider process terminated (exit code: \(exitCode))")
                print("⚠️ Aider terminated with exit code: \(exitCode)")
            }
        }

        do {
            try process.run()
            self.process = process
            self.isRunning = true
            self.initializationStatus = "Running"
            appendSystemMessage("🚀 Aider connected on \(projectPath)")
            print("✅ Aider process started successfully (PID: \(process.processIdentifier))")
        } catch {
            let errorMsg = "❌ Failed to launch: \(error.localizedDescription)"
            appendSystemMessage(errorMsg)
            print(errorMsg)
            print("   Full error: \(error)")
        }
    }
    
    // MARK: - Messaging
    
    func sendUserMessage(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        messages.append(ChatMessage(content: text, isUser: true))
        isThinking = true
        
        if let pipe = inputPipe, isRunning {
            let cleanText = text.replacingOccurrences(of: "\n", with: " ")
            if let data = "\(cleanText)\n".data(using: .utf8) {
                try? pipe.fileHandleForWriting.write(contentsOf: data)
            }
        } else {
            appendSystemMessage("⚠️ Aider is not running.")
            isThinking = false
        }
    }
    
    // MARK: - Output Throttling
    
    private func flushOutputBuffer() {
        guard !pendingOutputBuffer.isEmpty else { return }
        let text = pendingOutputBuffer
        pendingOutputBuffer = ""
        
        // 清理 ANSI
        let cleanText = text.replacingOccurrences(
            of: "\\x1B(?:\\[[0-9;]*[mK]?)",
            with: "",
            options: .regularExpression
        )
        
        if cleanText.isEmpty { return }
        
        if cleanText.contains("> ") || cleanText.contains("? ") {
            isThinking = false
        } else {
            isThinking = true
        }
        
        // 修正：使用 let 避免警告，因为 struct 是值类型，这里并没有原地修改
        if let lastMsg = messages.last, !lastMsg.isUser {
            let newContent = lastMsg.content + cleanText
            messages[messages.count - 1] = ChatMessage(content: newContent, isUser: false)
        } else {
            messages.append(ChatMessage(content: cleanText, isUser: false))
        }
    }
    
    // MARK: - Lifecycle
    
    func stop() {
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

// 节流器工具类
class Throttler {
    private var workItem: DispatchWorkItem = DispatchWorkItem(block: {})
    private var previousRun: Date = Date.distantPast
    private let queue: DispatchQueue
    private let minimumDelay: TimeInterval

    init(minimumDelay: TimeInterval, queue: DispatchQueue = DispatchQueue.main) {
        self.minimumDelay = minimumDelay
        self.queue = queue
    }

    func throttle(_ block: @escaping () -> Void) {
        workItem.cancel()
        workItem = DispatchWorkItem() { [weak self] in
            self?.previousRun = Date()
            block()
        }
        let delay = previousRun.timeIntervalSinceNow > -minimumDelay ? minimumDelay : 0
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
}