import SwiftUI
import Combine
import AppKit

class GeminiLinkLogic: ObservableObject {
    // MARK: - Settings
    @Published var projectRoot: String = UserDefaults.standard.string(forKey: "ProjectRoot") ?? "/Users/YourName/Dev/Project" {
        didSet { UserDefaults.standard.set(projectRoot, forKey: "ProjectRoot") }
    }
    @Published var isListening: Bool = false
    @Published var autoPush: Bool = false
    @Published var magicPaste: Bool = false
    
    // MARK: - State
    @Published var logs: [LogEntry] = []
    @Published var lastActivityTime: Date = Date()
    
    private var timer: Timer?
    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int = 0
    
    struct LogEntry: Identifiable {
        let id = UUID()
        let time = Date()
        let message: String
        let type: LogType
    }
    
    enum LogType { case info, success, error, warning }

    // MARK: - Protocols
    private let markerStart = "!!!B64_START!!!"
    private let markerEnd = "!!!B64_END!!!"
    
    // MARK: - Actions
    
    func toggleListening() {
        isListening.toggle()
        if isListening {
            lastChangeCount = pasteboard.changeCount
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.checkClipboard()
            }
            addLog("🎧 Started listening for Gemini Protocol...", type: .info)
        } else {
            timer?.invalidate()
            timer = nil
            addLog("zzZ Paused listening.", type: .warning)
        }
    }
    
    func selectProjectRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Root"
        
        if panel.runModal() == .OK, let url = panel.url {
            projectRoot = url.path
            addLog("📂 Target set to: \(url.lastPathComponent)", type: .info)
        }
    }
    
    // MARK: - Core Logic
    
    private func checkClipboard() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        
        guard let content = pasteboard.string(forType: .string),
              content.contains(markerStart) else { return }
        
        processClipboardContent(content)
    }
    
    private func processClipboardContent(_ rawText: String) {
        addLog("⚡️ Protocol detected! Processing...", type: .info)
        
        // Regex pattern to extract file path and content
        // Pattern matches: !!!B64_START!!! path \n content !!!B64_END!!!
        let pattern = try! NSRegularExpression(
            pattern: "\(NSRegularExpression.escapedPattern(for: markerStart))\\s+(.*?)\\s+(.*?)\\s+\(NSRegularExpression.escapedPattern(for: markerEnd))",
            options: .dotMatchesLineSeparators
        )
        
        let range = NSRange(rawText.startIndex..<rawText.endIndex, in: rawText)
        let matches = pattern.matches(in: rawText, options: [], range: range)
        
        if matches.isEmpty {
            addLog("⚠️ Detected marker but failed to parse content.", type: .warning)
            return
        }
        
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
            addLog("✅ Updated \(updatedFiles.count) files: \(updatedFiles.joined(separator: ", "))", type: .success)
            
            // Auto Git
            if autoPush {
                do {
                    let res = try GitService.shared.pushChanges(in: projectRoot, message: "Gemini Update: \(updatedFiles.joined(separator: ", "))")
                    addLog("☁️ Git Push Success", type: .success)
                    print(res)
                } catch {
                    addLog("❌ Git Failed: \(error.localizedDescription)", type: .error)
                }
            }
        }
    }
    
    private func writeToFile(relativePath: String, base64Content: String) -> Bool {
        guard let data = Data(base64Encoded: base64Content) else {
            addLog("❌ Base64 Decode Failed for \(relativePath)", type: .error)
            return false
        }
        
        let fullURL = URL(fileURLWithPath: projectRoot).appendingPathComponent(relativePath)
        
        do {
            try FileManager.default.createDirectory(at: fullURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fullURL)
            return true
        } catch {
            addLog("❌ Write Failed: \(error.localizedDescription)", type: .error)
            return false
        }
    }
    
    // MARK: - Generators (Prep & Verify)
    
    func generateInitContext() {
        // 1. Scan directory
        let fileManager = FileManager.default
        let rootURL = URL(fileURLWithPath: projectRoot)
        var structure = ""
        
        if let enumerator = fileManager.enumerator(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                let relativePath = fileURL.path.replacingOccurrences(of: projectRoot + "/", with: "")
                if relativePath.contains(".git") || relativePath.contains("node_modules") || relativePath.contains(".build") { continue }
                structure += "\(relativePath)\n"
            }
        }
        
        let prompt = """
        You are my Senior AI Pair Programmer.
        Current Project Path: \(projectRoot)
        Project Structure:
        \(structure)

        【PROTOCOL - STRICTLY ENFORCE】:
        1. NO Markdown blocks, NO explanations for code changes.
        2. Output COMPLETED file content in Base64 ONLY.
        3. Format:
        ```text
        \(markerStart) <relative_path>
        <base64_string>
        \(markerEnd)
        ```
        If multiple files, output consecutive blocks.
        Ready? Await my orders.
        """
        
        MagicPaster.shared.copyToClipboard(prompt)
        addLog("📋 Context copied!", type: .success)
        
        if magicPaste {
            MagicPaster.shared.pasteToBrowser()
        }
    }
    
    func generateVerification() {
        let diff = GitService.shared.getDiff(in: projectRoot)
        let prompt = """
        Please VERIFY my latest changes.
        Here is the `git diff`:
        \(diff)
        
        Check for bugs. If WRONG, send fix via Base64 Protocol. If CORRECT, say "Passed".
        """
        
        MagicPaster.shared.copyToClipboard(prompt)
        addLog("🛡️ Verification prompt copied!", type: .success)
        
        if magicPaste {
            MagicPaster.shared.pasteToBrowser()
        }
    }
    
    private func addLog(_ message: String, type: LogType) {
        DispatchQueue.main.async {
            self.logs.insert(LogEntry(message: message, type: type), at: 0)
            if self.logs.count > 50 { self.logs.removeLast() }
        }
    }
}
