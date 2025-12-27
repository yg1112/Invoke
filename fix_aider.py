import os

# 目标文件路径
file_path = 'Sources/Invoke/Features/GeminiLinkLogic.swift'

# 完整的、经过修正的 Swift 代码
# 1. processResponse: 正确转发 Aider
# 2. finalize: 不包含错误的 rawText 引用
# 3. init/didSet: 包含 Aider 自动启动
content = """import SwiftUI
import Combine
import AppKit
import UserNotifications

// MARK: - Models
struct ChangeLog: Identifiable, Codable {
    var id: String { commitHash }
    let commitHash: String
    let timestamp: Date
    let summary: String
    var isValidated: Bool = false
}

class GeminiLinkLogic: ObservableObject {
    static let shared = GeminiLinkLogic()
    
    @Published var projectRoot: String = UserDefaults.standard.string(forKey: "ProjectRoot") ?? "" {
        didSet {
            UserDefaults.standard.set(projectRoot, forKey: "ProjectRoot")
            loadLogs()
            if !projectRoot.isEmpty {
                startListening()
                // [Aider Integration] Start Aider on project switch
                Task { @MainActor in AiderService.shared.startAider(projectPath: projectRoot) }
            }
        }
    }
    
    enum GitMode: String, CaseIterable {
        case localOnly = "Local Only"
        case safe = "Safe"
        case yolo = "YOLO"
        var title: String { rawValue }
        var icon: String {
            switch self {
            case .localOnly: return "lock.shield"
            case .safe: return "arrow.triangle.branch"
            case .yolo: return "bolt.fill"
            }
        }
        var description: String {
            switch self {
            case .localOnly: return "Private. Commit locally."
            case .safe: return "Push branch & PR."
            case .yolo: return "Push to main."
            }
        }
    }
    
    @Published var gitMode: GitMode = GitMode(rawValue: UserDefaults.standard.string(forKey: "GitMode") ?? "yolo") ?? .yolo {
        didSet { UserDefaults.standard.set(gitMode.rawValue, forKey: "GitMode") }
    }
    
    @Published var isListening: Bool = false
    @Published var isProcessing: Bool = false
    @Published var processingStatus: String = ""
    @Published var changeLogs: [ChangeLog] = []
    
    private var timer: Timer?
    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int = 0
    private var lastUserClipboard: String = ""
    
    // 串行写入队列，防止多线程写入冲突
    private let fileWriteQueue = DispatchQueue(label: "com.fetch.filewriter", qos: .userInitiated)
    
    // 🛡️ Protocol V3 Definition
    private let magicTrigger = ">>> INVOKE"
    private let tagFileStart = "!!!FILE_START!!!"
    private let tagFileEnd = "!!!FILE_END!!!"
    
    init() {
        setupNotifications()
        if !projectRoot.isEmpty {
            loadLogs()
            startListening()
            // [Aider Integration] Start Aider on launch
            Task { @MainActor in AiderService.shared.startAider(projectPath: self.projectRoot) }
        }
    }
    
    func selectProjectRoot() {
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Select Root"
            NSApp.activate(ignoringOtherApps: true)
            if panel.runModal() == .OK, let url = panel.url {
                self.projectRoot = url.path
            }
        }
    }

    func startListening() {
        if isListening && timer != nil { return }
        isListening = true
        lastChangeCount = pasteboard.changeCount
        if let content = pasteboard.string(forType: .string) { lastUserClipboard = content }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
                self?.checkClipboard()
            }
            RunLoop.main.add(self.timer!, forMode: .common)
            print("👂 Listening started... (Timer on main RunLoop)")
        }
    }
    
    private func checkClipboard() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard let content = pasteboard.string(forType: .string) else { return }
        
        // 🛑 Ignore System Prompts to prevent loops
        let ignoreSig = "[System Instruction: " + "Fetch Protocol]"
        if content.contains(ignoreSig) { return }
        if content.contains("[Fetch Review Request]") { return }
        
        // 🔒 Trigger Check
        if content.contains(magicTrigger) {
            print("✅ Detected Trigger '>>> INVOKE'")
            processResponse(content)
        } else {
            if !content.contains(tagFileStart) { lastUserClipboard = content }
        }
    }
    
    // 🔥 PUBLIC API
    func processResponse(_ rawText: String) {
        setStatus("Processing...", isBusy: true)
        print("🔵 [Logic Debug] processResponse called. Input length: \(rawText.count)")
        
        // 解析放在后台
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let files = self.parseFiles(rawText)
            
            if files.isEmpty {
                print("⚠️ No files parsed! Forwarding to Aider...")
                // [Aider Integration] Forward chat messages to Aider
                Task { @MainActor in AiderService.shared.sendUserMessage(rawText) }
                return
            } else {
                print("✅ Parsed \(files.count) files.")
            }
            
            var modified: Set<String> = []
            
            // 写入操作改为串行同步，确保原子性
            self.fileWriteQueue.sync {
                for f in files {
                    if self.writeFile(f.path, f.content) {
                        modified.insert(f.path)
                    }
                }
            }
            
            self.finalize(Array(modified))
        }
    }
    
    // 🔥 Universal Parser
    private func parseFiles(_ text: String) -> [FilePayload] {
        var payloads: [FilePayload] = []
        
        // Strategy A: Protocol V3
        let v3Pattern = "!!!FILE_START!!!\\\\s+([^\\\\n]+)\\\\n(.*?)\\\\n!!!FILE_END!!!"
        if let v3Regex = try? NSRegularExpression(pattern: v3Pattern, options: [.dotMatchesLineSeparators]) {
            let matches = v3Regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
            let v3Files = matches.compactMap { m -> FilePayload? in
                guard let rPath = Range(m.range(at: 1), in: text),
                      let rContent = Range(m.range(at: 2), in: text) else { return nil }
                return FilePayload(path: String(text[rPath]).trimmingCharacters(in: .whitespacesAndNewlines), content: String(text[rContent]))
            }
            payloads.append(contentsOf: v3Files)
        }
        
        // Strategy B: Markdown
        let mdPattern = "```filepath:\\\\s*([^\\\\n]+)\\\\n(.*?)\\\\n```"
        if let mdRegex = try? NSRegularExpression(pattern: mdPattern, options: [.dotMatchesLineSeparators]) {
            let matches = mdRegex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
            let mdFiles = matches.compactMap { m -> FilePayload? in
                guard let rPath = Range(m.range(at: 1), in: text),
                      let rContent = Range(m.range(at: 2), in: text) else { return nil }
                return FilePayload(path: String(text[rPath]).trimmingCharacters(in: .whitespacesAndNewlines), content: String(text[rContent]))
            }
            payloads.append(contentsOf: mdFiles)
        }
        
        // Strategy C: Protocol V2 (Fallback)
        let v2Pattern = "<FILE_CONTENT\\\\s+path=\\"([^\\"]+)\\"\\\\s*>(.*?)</FILE_CONTENT>"
        if let v2Regex = try? NSRegularExpression(pattern: v2Pattern, options: [.dotMatchesLineSeparators]) {
            let matches = v2Regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
            let v2Files = matches.compactMap { m -> FilePayload? in
                guard let rPath = Range(m.range(at: 1), in: text),
                      let rContent = Range(m.range(at: 2), in: text) else { return nil }
                return FilePayload(path: String(text[rPath]), content: String(text[rContent]).trimmingCharacters(in: .newlines))
            }
            payloads.append(contentsOf: v2Files)
        }
        
        return payloads
    }
    
    private func writeFile(_ path: String, _ content: String) -> Bool {
        let url = URL(fileURLWithPath: projectRoot).appendingPathComponent(path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            
            if path.hasSuffix(".swift") {
                if !validateSwiftFile(content: content, path: path) {
                    print("⚠️ Swift validation failed for \(path), skipping write")
                    return false
                }
            }
            
            try content.write(to: url, atomically: true, encoding: .utf8)
            print("✅ Wrote: \(path)")
            return true
        } catch {
            print("❌ Write Failed: \(path) - \(error)")
            return false
        }
    }
    
    private func validateSwiftFile(content: String, path: String) -> Bool {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("\(UUID().uuidString).swift")
        
        guard (try? content.write(to: tempFile, atomically: true, encoding: .utf8)) != nil else {
            return false
        }
        
        defer { try? FileManager.default.removeItem(at: tempFile) }
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        task.arguments = ["-typecheck", tempFile.path]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return true
        }
    }
    
    private func finalize(_ files: [String]) {
        DispatchQueue.main.async {
            if files.isEmpty { 
                self.setStatus("No valid tags found", isBusy: false)
                return 
            }
            
            self.setStatus("Running build check...", isBusy: true)
            self.validateProjectBuild { [weak self] isValid in
                guard let self = self else { return }
                
                if !isValid {
                    self.setStatus("Build failed - changes rejected", isBusy: false)
                    self.sendBuildErrorToGemini()
                    return
                }
                
                let summary = "Update: \(files.map{URL(fileURLWithPath: $0).lastPathComponent}.joined(separator: ", "))"
                self.setStatus("Committing...", isBusy: true)
                self.commitAndPush(summary)
            }
        }
    }
    
    private func validateProjectBuild(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global().async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
            task.arguments = ["build", "--quiet"]
            task.currentDirectoryURL = URL(fileURLWithPath: self.projectRoot)
            task.standardOutput = Pipe()
            task.standardError = Pipe()
            
            do {
                try task.run()
                task.waitUntilExit()
                completion(task.terminationStatus == 0)
            } catch {
                completion(true)
            }
        }
    }
    
    private func sendBuildErrorToGemini() {
        DispatchQueue.global().async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
            task.arguments = ["build"]
            task.currentDirectoryURL = URL(fileURLWithPath: self.projectRoot)
            task.standardOutput = Pipe()
            task.standardError = Pipe()
            
            do {
                try task.run()
                task.waitUntilExit()
                
                let errorPipe = task.standardError as! Pipe
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorOutput = String(data: errorData, encoding: .utf8) ?? "Build failed"
                
                let prompt = \"\"\"
                [Fetch Build Error]
                Build failed with errors:
                
                \(errorOutput)
                
                Please fix the code and resubmit using !!!FILE_START!!! format, starting with >>> INVOKE.
                \"\"\"
                
                DispatchQueue.main.async {
                    self.pasteboard.clearContents()
                    self.pasteboard.setString(prompt, forType: .string)
                    MagicPaster.shared.pasteToBrowser()
                }
            } catch {
                print("⚠️ Could not capture build error: \(error)")
            }
        }
    }
    
    private func commitAndPush(_ msg: String) {
        DispatchQueue.global().async {
            _ = try? GitService.shared.commitChanges(in: self.projectRoot, message: msg)
            let hash = (try? GitService.shared.run(args: ["rev-parse", "--short", "HEAD"], in: self.projectRoot)) ?? "done"
            
            if self.gitMode == .yolo {
                _ = try? GitService.shared.pushToRemote(in: self.projectRoot)
            } else if self.gitMode == .safe {
                let b = "fetch-\(hash)"
                try? GitService.shared.createBranch(in: self.projectRoot, name: b)
                _ = try? GitService.shared.pushBranch(in: self.projectRoot, branch: b)
            }
            
            DispatchQueue.main.async {
                self.setStatus("", isBusy: false)
                self.changeLogs.insert(ChangeLog(commitHash: hash, timestamp: Date(), summary: msg), at: 0)
                self.saveLogs()
                NSSound(named: "Glass")?.play()
            }
        }
    }
    
    // MARK: - User Facing
    
    func copyGemSetupGuide() {
        let header = "[System Instruction: Fetch Protocol v3]"
        
        let guide = \"\"\"
        \(header)
        
        You are the backend logic for a local execution engine.
        The executor is extremely strict and will CRASH if output is malformed.
        
        ⚠️ CRITICAL COMPLIANCE RULES:
        1. NO conversational filler. Do not say "Here is the code" or "I fixed it".
        2. Output ONLY the file changes.
        3. Start response with exactly: >>> INVOKE
        4. Use this EXACT format for every file, no exceptions:
        
        !!!FILE_START!!!
        path/to/file.ext
        [...Put the full raw file content here...]
        !!!FILE_END!!!
        
        5. If you use Markdown code blocks (```), ensure they are OUTSIDE the !!! tags.
        6. Do not truncate code. The executor cannot "fill in the rest".
        7. Each file must be complete and valid.
        \"\"\"
        
        pasteboard.clearContents()
        pasteboard.setString(guide, forType: .string)
        showNotification("Protocol V3 Copied", "Paste this to reset your AI session")
    }
    
    func manualApplyFromClipboard() { checkClipboard() }
    
    func reviewLastChange() {
        guard let log = changeLogs.first else { return }
        setStatus("Fetching Diff...", isBusy: true)
        DispatchQueue.global().async {
            let diff = (try? GitService.shared.run(args: ["show", log.commitHash], in: self.projectRoot)) ?? ""
            let p = \"\"\"
            [Fetch Review Request]
            Check commit \(log.commitHash):
            
            \(diff)
            
            If fix needed, use !!!FILE_START!!! format and start with >>> INVOKE.
            \"\"\"
            DispatchQueue.main.async {
                self.setStatus("", isBusy: false)
                self.pasteboard.clearContents()
                self.pasteboard.setString(p, forType: .string)
                MagicPaster.shared.pasteToBrowser()
            }
        }
    }

    func closePR(for log: ChangeLog) {
        setStatus("Deleting Branch...", isBusy: true)
        DispatchQueue.global().async {
            let branchName = "fetch-\(log.commitHash)"
            GitService.shared.deleteBranch(in: self.projectRoot, branch: branchName)
            
            DispatchQueue.main.async {
                self.setStatus("", isBusy: false)
                if let index = self.changeLogs.firstIndex(where: { $0.id == log.id }) {
                    self.changeLogs.remove(at: index)
                    self.saveLogs()
                }
            }
        }
    }
    
    private func setStatus(_ t: String, isBusy: Bool) { self.processingStatus = t; self.isProcessing = isBusy }
    
    // MARK: - Notifications
    private func setupNotifications() {
        // 修复：防止命令行模式下崩溃
        guard Bundle.main.bundleIdentifier != nil else { print("⚠️ Debug Mode: Skipping notifications"); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    
    private func showNotification(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
    
    private struct FilePayload { let path: String; let content: String }
    private func getLogFileURL() -> URL? {
        guard !projectRoot.isEmpty else { return nil }
        let f = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".fetch_logs")
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f.appendingPathComponent("\(URL(fileURLWithPath: projectRoot).lastPathComponent).json")
    }
    private func saveLogs() { if let u = getLogFileURL() { try? JSONEncoder().encode(changeLogs).write(to: u) } }
    private func loadLogs() { if let u = getLogFileURL(), let d = try? Data(contentsOf: u) { changeLogs = (try? JSONDecoder().decode([ChangeLog].self, from: d)) ?? [] } }
}
"""

with open(file_path, 'w') as f:
    f.write(content)

print("✅ reset_gemini.py: 已成功重写 GeminiLinkLogic.swift！")