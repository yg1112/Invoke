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
        }
    }
    @Published var isListening: Bool = false
    
    // MARK: - Data Source
    @Published var changeLogs: [ChangeLog] = []
    
    private var timer: Timer?
    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int = 0
    private let markerStart = "!!!B64_START!!!"
    private let markerEnd = "!!!B64_END!!!"
    
    init() {
        if !projectRoot.isEmpty { loadLogs() }
    }
    
    // MARK: - File Selection (Fixed & Stable)
    func selectProjectRoot() {
        // 必须在主线程执行 UI 操作
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false      // 禁止选文件（会导致文件变灰，正常现象）
            panel.canChooseDirectories = true // 只能选文件夹
            panel.allowsMultipleSelection = false
            panel.title = "Select Project Root"
            panel.prompt = "Set Root"
            panel.treatsFilePackagesAsDirectories = false
            
            // ⚠️ 修复闪退的关键：
            // 1. 先把 App 激活到前台
            NSApp.activate(ignoringOtherApps: true)
            
            // 2. 使用 runModal() 而不是 begin()
            // runModal 会阻塞当前线程直到用户选择，这是最安全的方式
            if panel.runModal() == .OK, let url = panel.url {
                self.projectRoot = url.path
            }
        }
    }

    // MARK: - Core Flow
    func toggleListening() {
        isListening.toggle()
        if isListening {
            lastChangeCount = pasteboard.changeCount
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.checkClipboard()
            }
        } else {
            timer?.invalidate()
            timer = nil
        }
    }
    
    private func checkClipboard() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        
        guard let content = pasteboard.string(forType: .string),
              content.contains(markerStart) else { return }
        
        processClipboardContent(content)
    }
    
    private func processClipboardContent(_ rawText: String) {
        let pattern = try! NSRegularExpression(
            pattern: "\(NSRegularExpression.escapedPattern(for: markerStart))\\s+(.*?)\\s+(.*?)\\s+\(NSRegularExpression.escapedPattern(for: markerEnd))",
            options: .dotMatchesLineSeparators
        )
        let matches = pattern.matches(in: rawText, options: [], range: NSRange(rawText.startIndex..<rawText.endIndex, in: rawText))
        
        if matches.isEmpty { return }
        
        var updatedFiles: [String] = []
        
        for match in matches {
            if let pathRange = Range(match.range(at: 1), in: rawText),
               let contentRange = Range(match.range(at: 2), in: rawText) {
                let relPath = String(rawText[pathRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                let b64Content = String(rawText[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                
                if writeToFile(relativePath: relPath, base64Content: b64Content) {
                    updatedFiles.append(relPath)
                }
            }
        }
        
        if !updatedFiles.isEmpty {
            let summary = "Update: \(updatedFiles.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))"
            autoCommitAndPush(message: summary, summary: summary)
        }
    }
    
    private func writeToFile(relativePath: String, base64Content: String) -> Bool {
        guard let data = Data(base64Encoded: base64Content) else { return false }
        let fullURL = URL(fileURLWithPath: projectRoot).appendingPathComponent(relativePath)
        do {
            try FileManager.default.createDirectory(at: fullURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fullURL)
            return true
        } catch {
            print("Write error: \(error)")
            return false
        }
    }
    
    // MARK: - Git & Logging Logic
    private func autoCommitAndPush(message: String, summary: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try GitService.shared.pushChanges(in: self.projectRoot, message: message)
                
                // Try to get hash, fallback to "unknown" if fails
                let commitHash = (try? GitService.shared.run(args: ["rev-parse", "--short", "HEAD"], in: self.projectRoot)) ?? "unknown"
                
                DispatchQueue.main.async {
                    let newLog = ChangeLog(commitHash: commitHash, timestamp: Date(), summary: summary)
                    self.changeLogs.insert(newLog, at: 0)
                    self.saveLogs()
                    NSSound(named: "Glass")?.play()
                }
            } catch {
                print("Git Error: \(error)")
            }
        }
    }
    
    // MARK: - Protocol & Validation
    func copyProtocol() {
        let structure = "(Project structure omitted)"
        let prompt = """
        You are my Senior AI Pair Programmer.
        Current Project Structure:
        \(structure)

        【PROTOCOL - STRICTLY ENFORCE】:
        1. When I ask for changes, DO NOT explain.
        2. Output only the CHANGED files using this Base64 format:
        
        ```text
        \(markerStart) <relative_path>
        <base64_string_of_full_file_content>
        \(markerEnd)
        ```
        
        3. If multiple files change, output multiple blocks sequentially.
        4. I will auto-apply these changes.
        
        Ready? Await my instructions.
        """
        
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)
    }
    
    func validateCommit(_ log: ChangeLog) {
        DispatchQueue.global().async {
            let diff = try? GitService.shared.run(args: ["show", log.commitHash], in: self.projectRoot)
            
            let prompt = """
            Please VALIDATE this specific commit: \(log.commitHash).
            
            I have just applied these changes locally. Here is the `git show` output:
            
            \(diff ?? "Error reading diff")
            
            Task:
            1. Review the code changes for logic errors or bugs.
            2. If CORRECT, reply: "Commit \(log.commitHash) Verified: [Short Summary]"
            3. If WRONG, output the FIX using the Base64 Protocol immediately.
            """
            
            DispatchQueue.main.async {
                self.pasteboard.clearContents()
                self.pasteboard.setString(prompt, forType: .string)
            }
        }
    }
    
    func toggleValidationStatus(for id: String) {
        if let index = changeLogs.firstIndex(where: { $0.id == id }) {
            changeLogs[index].isValidated.toggle()
            saveLogs()
        }
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
