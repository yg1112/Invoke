import SwiftUI
import Combine
import AppKit

// MARK: - Data Models
struct ChangeLog: Identifiable, Codable {
    var id: String { commitHash }
    let commitHash: String
    let timestamp: Date
    let summary: String
    var isValidated: Bool = false
}

class GeminiLinkLogic: ObservableObject {
    // MARK: - Settings
    @Published var projectRoot: String = UserDefaults.standard.string(forKey: "ProjectRoot") ?? "" {
        didSet {
            UserDefaults.standard.set(projectRoot, forKey: "ProjectRoot")
            loadLogs()
            // 选择项目后自动开启监听
            if !projectRoot.isEmpty && !isListening {
                startListening()
            }
        }
    }
    
    // Git 模式：Local Only / Safe (PR) / YOLO (Direct Push)
    enum GitMode: String, CaseIterable {
        case localOnly = "Local Only"
        case safe = "Safe"
        case yolo = "YOLO"
        
        var description: String {
            switch self {
            case .localOnly: return "Local commits only"
            case .safe: return "Create PR"
            case .yolo: return "Direct Push"
            }
        }
    }
    
    @Published var gitMode: GitMode = GitMode(rawValue: UserDefaults.standard.string(forKey: "GitMode") ?? "yolo") ?? .yolo {
        didSet {
            UserDefaults.standard.set(gitMode.rawValue, forKey: "GitMode")
        }
    }
    
    @Published var isListening: Bool = false
    @Published var isProcessing: Bool = false  // 本地编辑状态指示
    @Published var processingStatus: String = ""  // 处理状态描述
    
    // MARK: - Data Source
    @Published var changeLogs: [ChangeLog] = []
    
    private var timer: Timer?
    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int = 0
    
    // 🎯 隐形剪贴板：保存用户最后的"非协议"内容
    private var lastUserClipboard: String = ""
    private var lastUserClipboardTime: Date = Date()
    
    // Protocol Markers
    private let markerStart = "!!!B64_START!!!"
    private let markerEnd = "!!!B64_END!!!"
    
    init() {
        if !projectRoot.isEmpty { loadLogs() }
    }
    
    // MARK: - File Selection (Fixed & Async)
    func selectProjectRoot() {
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Select Root"
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            
            NSApp.activate(ignoringOtherApps: true)
            
            NSApp.activate(ignoringOtherApps: true)
            
            panel.begin { response in
                if response == .OK, let url = panel.url {
                    DispatchQueue.main.async {
                        self.projectRoot = url.path
                        print("📂 Project Root Set: \(self.projectRoot)")
                    }
                }
            }
        }
    }

    // MARK: - Core Flow (自动监听)
    
    /// 启动自动监听（选择项目后自动调用）
    func startListening() {
        guard !isListening else { return }
        isListening = true
        print("👂 Auto-listening ACTIVATED - monitoring clipboard...")
        lastChangeCount = pasteboard.changeCount
        
        // 🎯 保存当前剪贴板作为用户的"正常"内容
        if let currentContent = pasteboard.string(forType: .string),
           !currentContent.contains(markerStart) {
            lastUserClipboard = currentContent
            lastUserClipboardTime = Date()
            print("💾 Initial user clipboard saved: \(String(currentContent.prefix(50)))...")
        }
        
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
        showNotification(title: "Ready", body: "Invisible clipboard mode active")
    }
    
    /// 停止监听（一般不需要手动调用）
    func stopListening() {
        guard isListening else { return }
        isListening = false
        print("🛑 Listen mode STOPPED")
        timer?.invalidate()
        timer = nil
    }
    
    private func checkClipboard() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        
        guard let content = pasteboard.string(forType: .string) else { return }
        
        // 🎯 检测 Base64 单行流格式 (echo '...' | base64 -d > file)
        if content.contains("base64 -d >") || content.contains("base64 -d>") {
            print("🔍 Detected Base64 one-liner format!")
            print("📋 Content length: \(content.count) chars")
            
            restoreUserClipboardImmediately()
            
            DispatchQueue.main.async {
                self.isProcessing = true
                self.processingStatus = "Detecting code..."
            }
            
            showNotification(title: "Code Detected", body: "Applying changes...")
            processBase64OneLiner(content)
            
        } else if content.contains("cat <<") && content.contains("EOF") {
            // 兼容 cat << EOF 格式
            print("🔍 Detected shell script format!")
            restoreUserClipboardImmediately()
            
            DispatchQueue.main.async {
                self.isProcessing = true
                self.processingStatus = "Detecting code..."
            }
            
            showNotification(title: "Code Detected", body: "Applying changes...")
            processShellScript(content)
            
        } else if content.contains(markerStart) {
            // 兼容旧的 Base64 标记格式
            print("🔍 Detected legacy Base64 protocol!")
            restoreUserClipboardImmediately()
            
            DispatchQueue.main.async {
                self.isProcessing = true
                self.processingStatus = "Detecting code..."
            }
            
            showNotification(title: "Code Detected", body: "Applying changes...")
            processClipboardContent(content)
            
        } else {
            // 普通内容 → 保存为用户的"正常"剪贴板
            if !content.isEmpty && content.count < 50000 && !content.contains("@code") {
                lastUserClipboard = content
                lastUserClipboardTime = Date()
            }
        }
    }
    
    /// 立刻恢复用户剪贴板（让协议代码"消失"）
    private func restoreUserClipboardImmediately() {
        guard !lastUserClipboard.isEmpty else {
            print("⚠️ No previous user clipboard to restore")
            return
        }
        
        // 微小延迟确保我们已经读取了协议内容
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.pasteboard.clearContents()
            self.pasteboard.setString(self.lastUserClipboard, forType: .string)
            self.lastChangeCount = self.pasteboard.changeCount  // 防止重复触发
            print("♻️ User clipboard restored instantly!")
        }
    }
    
    // MARK: - 新格式：Base64 单行流 (echo '...' | base64 -d > file)
    
    private func processBase64OneLiner(_ rawText: String) {
        DispatchQueue.main.async {
            self.processingStatus = "Parsing Base64 one-liners..."
        }
        
        // 匹配格式: echo '<base64>' | base64 -d > path/to/file.swift
        // 或者: echo "<base64>" | base64 -d > path/to/file.swift
        let pattern = try! NSRegularExpression(
            pattern: "echo\\s+['\"]([A-Za-z0-9+/=]+)['\"]\\s*\\|\\s*base64\\s+-d\\s*>\\s*([^\\n\\s]+)",
            options: []
        )
        let matches = pattern.matches(in: rawText, options: [], range: NSRange(rawText.startIndex..<rawText.endIndex, in: rawText))
        
        if matches.isEmpty {
            print("⚠️ No valid echo | base64 -d commands found")
            print("📝 Content preview: \(String(rawText.prefix(500)))")
            
            DispatchQueue.main.async {
                self.isProcessing = false
                self.processingStatus = ""
                self.showNotification(title: "Parse Error", body: "No valid Base64 one-liner found")
            }
            return
        }
        
        print("✅ Found \(matches.count) file(s) to create/update")
        DispatchQueue.main.async {
            self.processingStatus = "Decoding \(matches.count) file(s)..."
        }
        
        var updatedFiles: [String] = []
        
        for match in matches {
            if let base64Range = Range(match.range(at: 1), in: rawText),
               let pathRange = Range(match.range(at: 2), in: rawText) {
                let base64String = String(rawText[base64Range])
                let filePath = String(rawText[pathRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                
                print("📄 Processing: \(filePath)")
                print("📦 Base64 length: \(base64String.count) chars")
                
                // 解码 Base64 为真实代码
                if let data = Data(base64Encoded: base64String),
                   let decodedContent = String(data: data, encoding: .utf8) {
                    print("✅ Decoded to \(decodedContent.count) chars of code")
                    
                    if writeFileDirectly(relativePath: filePath, content: decodedContent) {
                        updatedFiles.append(filePath)
                    }
                } else {
                    print("❌ Failed to decode Base64 for: \(filePath)")
                }
            }
        }
        
        if !updatedFiles.isEmpty {
            DispatchQueue.main.async {
                self.processingStatus = "Committing changes..."
            }
            let summary = "Update: \(updatedFiles.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))"
            autoCommitAndPush(message: summary, summary: summary)
        } else {
            DispatchQueue.main.async {
                self.isProcessing = false
                self.processingStatus = ""
                self.showNotification(title: "No Changes", body: "Failed to decode files")
            }
        }
    }
    
    // MARK: - 兼容格式：Shell 脚本解析 (cat << 'EOF' > file)
    
    private func processShellScript(_ rawText: String) {
        DispatchQueue.main.async {
            self.processingStatus = "Parsing shell commands..."
        }
        
        // 匹配格式: cat << 'EOF' > path/to/file.swift ... EOF
        let pattern = try! NSRegularExpression(
            pattern: "cat\\s*<<\\s*'?EOF'?\\s*>\\s*([^\\n]+)\\n([\\s\\S]*?)\\nEOF",
            options: []
        )
        let matches = pattern.matches(in: rawText, options: [], range: NSRange(rawText.startIndex..<rawText.endIndex, in: rawText))
        
        if matches.isEmpty {
            print("⚠️ No valid cat << EOF blocks found")
            print("📝 Content preview: \(String(rawText.prefix(500)))")
            
            DispatchQueue.main.async {
                self.isProcessing = false
                self.processingStatus = ""
                self.showNotification(title: "Parse Error", body: "No valid shell commands found")
            }
            return
        }
        
        print("✅ Found \(matches.count) file(s) to create/update")
        DispatchQueue.main.async {
            self.processingStatus = "Writing \(matches.count) file(s)..."
        }
        
        var updatedFiles: [String] = []
        
        for match in matches {
            if let pathRange = Range(match.range(at: 1), in: rawText),
               let contentRange = Range(match.range(at: 2), in: rawText) {
                let filePath = String(rawText[pathRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                let fileContent = String(rawText[contentRange])
                
                print("📄 Processing: \(filePath)")
                print("📦 Content length: \(fileContent.count) chars")
                
                if writeFileDirectly(relativePath: filePath, content: fileContent) {
                    updatedFiles.append(filePath)
                }
            }
        }
        
        if !updatedFiles.isEmpty {
            DispatchQueue.main.async {
                self.processingStatus = "Committing changes..."
            }
            let summary = "Update: \(updatedFiles.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))"
            autoCommitAndPush(message: summary, summary: summary)
        } else {
            DispatchQueue.main.async {
                self.isProcessing = false
                self.processingStatus = ""
                self.showNotification(title: "No Changes", body: "No files were updated")
            }
        }
    }
    
    /// 直接写入文件（不需要 Base64 解码）
    private func writeFileDirectly(relativePath: String, content: String) -> Bool {
        let fullURL = URL(fileURLWithPath: projectRoot).appendingPathComponent(relativePath)
        do {
            try FileManager.default.createDirectory(at: fullURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: fullURL, atomically: true, encoding: .utf8)
            print("✅ Wrote: \(relativePath) (\(content.count) chars)")
            return true
        } catch {
            print("❌ Write error: \(error)")
            return false
        }
    }
    
    // MARK: - 旧格式：Base64 解析（兼容）
    
    private func processClipboardContent(_ rawText: String) {
        DispatchQueue.main.async {
            self.processingStatus = "Parsing Base64 blocks..."
        }
        
        let pattern = try! NSRegularExpression(
            pattern: "\(NSRegularExpression.escapedPattern(for: markerStart))\\s+([\\w/\\-\\.]+\\.\\w+)[\\s\\n]+([A-Za-z0-9+/=\\s\\n]+?)[\\s\\n]*\(NSRegularExpression.escapedPattern(for: markerEnd))",
            options: [.dotMatchesLineSeparators]
        )
        let matches = pattern.matches(in: rawText, options: [], range: NSRange(rawText.startIndex..<rawText.endIndex, in: rawText))
        
        if matches.isEmpty {
            print("⚠️ No valid Base64 blocks found in clipboard")
            print("📝 Raw text length: \(rawText.count) chars")
            
            DispatchQueue.main.async {
                self.isProcessing = false
                self.processingStatus = ""
                self.showNotification(title: "Parse Error", body: "No valid Base64 blocks found. Check Gemini output format.")
            }
            return
        }
        
        print("✅ Found \(matches.count) file(s) to update")
        DispatchQueue.main.async {
            self.processingStatus = "Writing \(matches.count) file(s)..."
        }
        
        var updatedFiles: [String] = []
        
        for match in matches {
            if let pathRange = Range(match.range(at: 1), in: rawText),
               let contentRange = Range(match.range(at: 2), in: rawText) {
                let relPath = String(rawText[pathRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                let b64Content = String(rawText[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                
                print("📄 Processing file: \(relPath)")
                print("📦 Base64 content length: \(b64Content.count) chars")
                print("📦 Base64 preview: \(String(b64Content.prefix(100)))...")
                
                if b64Content.isEmpty || b64Content == "+" {
                    print("❌ Invalid Base64 content for \(relPath): content is empty or just '+'")
                    DispatchQueue.main.async {
                        self.showNotification(title: "Invalid Content", body: "Base64 content for \(relPath) is empty")
                    }
                    continue
                }
                
                if writeToFile(relativePath: relPath, base64Content: b64Content) {
                    updatedFiles.append(relPath)
                }
            }
        }
        
        if !updatedFiles.isEmpty {
            DispatchQueue.main.async {
                self.processingStatus = "Committing changes..."
            }
            let summary = "Update: \(updatedFiles.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))"
            autoCommitAndPush(message: summary, summary: summary)
        } else {
            DispatchQueue.main.async {
                self.isProcessing = false
                self.processingStatus = ""
                self.showNotification(title: "No Changes", body: "No files were updated")
            }
        }
    }
    
    private func writeToFile(relativePath: String, base64Content: String) -> Bool {
        // 清理 Base64 内容：移除所有空格、换行符等
        let cleanedBase64 = base64Content
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\t", with: "")
        
        print("🧹 Cleaned Base64 length: \(cleanedBase64.count) chars")
        
        guard let data = Data(base64Encoded: cleanedBase64) else {
            print("❌ Invalid Base64 for: \(relativePath)")
            print("📝 First 100 chars of cleaned: \(String(cleanedBase64.prefix(100)))")
            print("📝 Last 50 chars of cleaned: \(String(cleanedBase64.suffix(50)))")
            return false
        }
        let fullURL = URL(fileURLWithPath: projectRoot).appendingPathComponent(relativePath)
        do {
            try FileManager.default.createDirectory(at: fullURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fullURL)
            print("✅ Wrote: \(relativePath) (\(data.count) bytes)")
            return true
        } catch {
            print("❌ Write error: \(error)")
            return false
        }
    }
    
    private func autoCommitAndPush(message: String, summary: String) {
        print("🚀 Starting Git operation (\(gitMode.rawValue) mode)...")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // 1. Commit 本地改动
                _ = try GitService.shared.commitChanges(in: self.projectRoot, message: message)
                let commitHash = (try? GitService.shared.run(args: ["rev-parse", "--short", "HEAD"], in: self.projectRoot)) ?? "unknown"
                
                // 2. Local Only 模式：只提交不推送
                if self.gitMode == .localOnly {
                    print("✅ Local commit completed: \(commitHash)")
                    DispatchQueue.main.async {
                        self.isProcessing = false
                        self.processingStatus = ""
                        let newLog = ChangeLog(commitHash: commitHash, timestamp: Date(), summary: summary)
                        self.changeLogs.insert(newLog, at: 0)
                        self.saveLogs()
                        self.showNotification(title: "Local Commit", body: summary)
                        NSSound(named: "Glass")?.play()
                    }
                    return
                }
                
                // 3. 根据模式执行推送操作
                if self.gitMode == .yolo {
                    // YOLO 模式：直接 push
                    _ = try GitService.shared.pushToRemote(in: self.projectRoot)
                    print("✅ Git push successful: \(commitHash)")
                    
                    DispatchQueue.main.async {
                        self.isProcessing = false
                        self.processingStatus = ""
                        let newLog = ChangeLog(commitHash: commitHash, timestamp: Date(), summary: summary)
                        self.changeLogs.insert(newLog, at: 0)
                        self.saveLogs()
                        self.showNotification(title: "Pushed", body: summary)
                        NSSound(named: "Glass")?.play()
                    }
                } else {
                    // Safe 模式：创建 PR
                    let branchName = "invoke-\(commitHash)"
                    try GitService.shared.createBranch(in: self.projectRoot, name: branchName)
                    _ = try GitService.shared.pushBranch(in: self.projectRoot, branch: branchName)
                    
                    print("✅ Branch created and pushed: \(branchName)")
                    
                    DispatchQueue.main.async {
                        self.isProcessing = false
                        self.processingStatus = ""
                        let newLog = ChangeLog(commitHash: commitHash, timestamp: Date(), summary: summary)
                        self.changeLogs.insert(newLog, at: 0)
                        self.saveLogs()
                        self.showNotification(title: "PR Ready", body: "Branch: \(branchName)")
                        NSSound(named: "Glass")?.play()
                    }
                }
            } catch {
                print("❌ Git Error: \(error)")
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.processingStatus = ""
                    self.showNotification(title: "Git Failed", body: error.localizedDescription)
                }
            }
        }
    }
    
    // MARK: - Manual Apply (手动应用剪贴板内容)
    
    /// 手动触发剪贴板解析（当自动检测失败时使用）
    func manualApplyFromClipboard() {
        print("📥 Manual Apply triggered - reading clipboard...")
        
        guard let content = pasteboard.string(forType: .string) else {
            print("⚠️ Clipboard is empty")
            showNotification(title: "Empty Clipboard", body: "No content to apply")
            return
        }
        
        // 优先检测 Base64 单行流格式 (最新格式)
        if content.contains("base64 -d >") || content.contains("base64 -d>") {
            print("🔍 Found Base64 one-liner format!")
            print("📋 Content length: \(content.count) chars")
            
            DispatchQueue.main.async {
                self.isProcessing = true
                self.processingStatus = "Manual apply..."
            }
            
            showNotification(title: "Applying Code", body: "Decoding Base64...")
            processBase64OneLiner(content)
            
        } else if content.contains("cat <<") && content.contains("EOF") {
            // 兼容 cat << EOF 格式
            print("🔍 Found shell script format!")
            
            DispatchQueue.main.async {
                self.isProcessing = true
                self.processingStatus = "Manual apply..."
            }
            
            showNotification(title: "Applying Code", body: "Processing shell commands...")
            processShellScript(content)
            
        } else if content.contains(markerStart) {
            // 兼容旧的 Base64 标记格式
            print("🔍 Found legacy Base64 protocol!")
            
            DispatchQueue.main.async {
                self.isProcessing = true
                self.processingStatus = "Manual apply..."
            }
            
            showNotification(title: "Applying Code", body: "Processing Base64...")
            processClipboardContent(content)
            
        } else {
            print("⚠️ No recognized format in clipboard")
            print("📋 Clipboard preview: \(String(content.prefix(200)))...")
            showNotification(title: "No Code Found", body: "Expected: echo '...' | base64 -d > file")
        }
    }
    
    // MARK: - Protocol & Validation (The Brain)
    
    /// 首次设置：复制 Gemini Personal Context 指令
    func copyGemSetupGuide() {
        print("📖 Copying Gemini Personal Context instruction...")
        
        // Base64 单行流格式 - 最省空间！
        let instruction = """
        When I say @code, provide a ONE-LINER shell command.
        
        Format: echo '<base64_string>' | base64 -d > path/to/file.swift
        
        Rules:
        - Encode the COMPLETE file content into a single-line Base64 string
        - Multiple files = multiple echo commands (each on its own line)
        - The output block must be ONE code block, minimal height
        - NO explanation, NO comments
        - For updates to large files, only show changed functions unless I ask for full file
        """
        
        pasteboard.clearContents()
        pasteboard.setString(instruction, forType: .string)
        showNotification(title: "Instruction Copied", body: "Paste to Gemini Settings > Personal Context")
        print("📋 Personal Context instruction copied")
    }
    
    /// 日常使用：复制 @code 咒语
    func copyProtocol() {
        print("🔗 @code button clicked...")
        
        // 🎯 保存当前用户剪贴板
        if let current = pasteboard.string(forType: .string),
           !current.contains("echo") && !current.contains("base64") {
            lastUserClipboard = current
            lastUserClipboardTime = Date()
        }
        
        let prompt = "@code"
        
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)
        lastChangeCount = pasteboard.changeCount
        
        showNotification(title: "@code ✓", body: "Paste to Gemini + your request")
        print("📋 @code copied")
    }
    
    /// Review 最后一次改动（点击 Review 按钮）
    func reviewLastChange() {
        guard let lastLog = changeLogs.first else {
            print("⚠️ No commits to review")
            showNotification(title: "Nothing to Review", body: "No recent changes")
            return
        }
        
        print("🔍 Reviewing commit: \(lastLog.commitHash)")
        
        DispatchQueue.global().async {
            let diff = try? GitService.shared.run(args: ["show", lastLog.commitHash], in: self.projectRoot)
            
            let prompt = """
            Please REVIEW this commit I just made:
            
            **Commit:** \(lastLog.commitHash)
            **Summary:** \(lastLog.summary)
            
            **Changes:**
            ```
            \(diff ?? "Error reading diff")
            ```
            
            **Task:**
            1. Analyze if the changes are correct and complete.
            2. If CORRECT, reply: "✅ Verified - changes look good!"
            3. If there are ISSUES, provide the FIX using the Base64 Protocol:
            
            ```text
            \(self.markerStart) <relative_path>
            <base64_string_of_full_file_content>
            \(self.markerEnd)
            ```
            
            Ready to review?
            """
            
            DispatchQueue.main.async {
                self.pasteboard.clearContents()
                self.pasteboard.setString(prompt, forType: .string)
                
                // 触发自动粘贴 (权限检查在 MagicPaster 内部处理)
                print("🎯 Auto-pasting review request...")
                MagicPaster.shared.pasteToBrowser()
            }
        }
    }
    
    func toggleValidationStatus(for id: String) {
        if let index = changeLogs.firstIndex(where: { $0.id == id }) {
            changeLogs[index].isValidated.toggle()
            saveLogs()
        }
    }
    
    // MARK: - Helper: File Scanner
    private func scanProjectStructure() -> String {
        guard !projectRoot.isEmpty else { return "(No project selected)" }
        let rootURL = URL(fileURLWithPath: projectRoot)
        var output = ""
        
        let fileManager = FileManager.default
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        
        // 使用 Enumerator 进行递归扫描
        if let enumerator = fileManager.enumerator(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: options) {
            for case let fileURL as URL in enumerator {
                let relativePath = fileURL.path.replacingOccurrences(of: rootURL.path + "/", with: "")
                
                // 🛡️ 智能过滤 (Smart Filter) - 关键！
                // 忽略垃圾文件，防止 Context 爆炸
                if relativePath.contains("node_modules") ||
                   relativePath.contains(".git") ||
                   relativePath.contains("build") ||
                   relativePath.contains(".DS_Store") ||
                   relativePath.hasSuffix(".lock") {
                    enumerator.skipDescendants() // 跳过该目录的内容
                    continue
                }
                
                output += "- \(relativePath)\n"
                
                // 简单限制一下长度，防止超大项目卡死
                if output.count > 10000 {
                    output += "... (truncated)\n"
                    break
                }
            }
        }
        return output.isEmpty ? "(Empty Project)" : output
    }
    
    // MARK: - Notification Helper
    private func showNotification(title: String, body: String) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = body
        notification.soundName = nil // 已经有 Glass 音效了
        NSUserNotificationCenter.default.deliver(notification)
    }
    
    // MARK: - Persistence
    private func getLogFileURL() -> URL? {
        guard !projectRoot.isEmpty else { return nil }
        let projectName = URL(fileURLWithPath: projectRoot).lastPathComponent
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".invoke_logs")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(projectName).json")
    }
    
    private func saveLogs() {
        guard let url = getLogFileURL() else { return }
        if let data = try? JSONEncoder().encode(changeLogs) {
            try? data.write(to: url)
        }
    }
    
    private func loadLogs() {
        guard let url = getLogFileURL(),
              let data = try? Data(contentsOf: url),
              let loaded = try? JSONDecoder().decode([ChangeLog].self, from: data) else {
            changeLogs = []
            return
        }
        changeLogs = loaded
    }
}
