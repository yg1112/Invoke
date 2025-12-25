import SwiftUI
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
    @Published var projectRoot: String = UserDefaults.standard.string(forKey: "ProjectRoot") ?? "" {
        didSet {
            UserDefaults.standard.set(projectRoot, forKey: "ProjectRoot")
            loadLogs()
            if !projectRoot.isEmpty { startListening() }
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
    
    // 🛡️ Protocol V2 Definition
    private let magicTrigger = ">>> INVOKE"
    // XML Tags (Split to avoid self-detection)
    private let tagFileStart = "<FILE_CONTENT"
    private let tagFileEnd = "</FILE_CONTENT>"
    private let attrPath = "path=\""
    
    init() {
        setupNotifications()
        if !projectRoot.isEmpty {
            loadLogs()
            startListening()
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
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in self?.checkClipboard() }
        print("👂 Listening started...")
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
        guard content.contains(magicTrigger) else {
            // Only backup user clipboard if it's NOT code intended for us
            if !content.contains(tagFileStart) { lastUserClipboard = content }
            return
        }
        
        print("⚡️ Detected Protocol V2 Content")
        processAllChanges(content)
    }
    
    private func processAllChanges(_ rawText: String) {
        restoreUserClipboardImmediately()
        setStatus("Processing...", isBusy: true)
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // 1. Sanitize: Remove Markdown code fences if AI added them
            let cleanText = self.sanitizeContent(rawText)
            
            var modified: Set<String> = []
            
            // 2. Parse XML Files
            let files = self.parseXMLFiles(cleanText)
            for f in files {
                if self.writeFile(f.path, f.content) {
                    modified.insert(f.path)
                }
            }
            
            self.finalize(Array(modified))
        }
    }
    
    // 🔥 Core Parser for V2 Protocol
    private func parseXMLFiles(_ text: String) -> [FilePayload] {
        // Regex: Matches <FILE_CONTENT path="path/to/file"> content </FILE_CONTENT>
        // Uses (?s) to let . match newlines
        let pattern = "<FILE_CONTENT\\s+path=\"([^\"]+)\"\\s*>(.*?)</FILE_CONTENT>"
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            print("❌ Regex Error")
            return []
        }
        
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        
        return matches.compactMap { m -> FilePayload? in
            guard let rPath = Range(m.range(at: 1), in: text),
                  let rContent = Range(m.range(at: 2), in: text) else { return nil }
            
            let path = String(text[rPath])
            // Trim leading/trailing newlines from content that might be introduced by XML formatting
            let content = String(text[rContent]).trimmingCharacters(in: .newlines)
            
            return FilePayload(path: path, content: content)
        }
    }
    
    private func sanitizeContent(_ text: String) -> String {
        // Remove markdown code block markers to prevent compilation errors
        var t = text
        if t.contains("```") {
            // Simple removal of fence lines
            t = t.replacingOccurrences(of: "^```\\w*$", with: "", options: .regularExpression)
        }
        return t
    }
    
    private func writeFile(_ path: String, _ content: String) -> Bool {
        let url = URL(fileURLWithPath: projectRoot).appendingPathComponent(path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            print("✅ Wrote: \(path)")
            return true
        } catch {
            print("❌ Write Failed: \(path) - \(error)")
            return false
        }
    }
    
    private func finalize(_ files: [String]) {
        DispatchQueue.main.async {
            if files.isEmpty { self.setStatus("No valid tags found", isBusy: false); return }
            let summary = "Update: \(files.map{URL(fileURLWithPath: $0).lastPathComponent}.joined(separator: ", "))"
            self.setStatus("Committing...", isBusy: true)
            self.commitAndPush(summary)
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
    
    /// Generates the NEW Protocol V2 System Prompt
    func copyGemSetupGuide() {
        let header = "[System Instruction: " + "Fetch Protocol v2]"
        
        let guide = """
        \(header)
        
        You are the backend for the 'Fetch' app.
        
        ⚠️ CRITICAL RULES:
        1. Start response with exactly: >>> INVOKE
        2. DO NOT use Markdown code blocks (```) for file content.
        3. Use XML tags for all code output.
        
        --- FORMAT: FULL FILE (Recommended) ---
        <FILE_CONTENT path="Sources/Path/To/File.swift">
        import SwiftUI
        // Put the FULL file content here.
        // No strict indentation needed for the tag, but content must be valid.
        </FILE_CONTENT>
        
        --- END OF RESPONSE ---
        >>> INVOKE
        """
        
        pasteboard.clearContents()
        pasteboard.setString(guide, forType: .string)
        showNotification("Protocol V2 Copied", "Paste this to reset your AI session")
    }
    
    func manualApplyFromClipboard() { checkClipboard() }
    
    func reviewLastChange() {
        guard let log = changeLogs.first else { return }
        setStatus("Fetching Diff...", isBusy: true)
        DispatchQueue.global().async {
            let diff = (try? GitService.shared.run(args: ["show", log.commitHash], in: self.projectRoot)) ?? ""
            let p = """
            [Fetch Review Request]
            Check commit \(log.commitHash):
            
            \(diff)
            
            If fix needed, use <FILE_CONTENT> format and start with >>> INVOKE.
            """
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
    
    private func restoreUserClipboardImmediately() {
        if !lastUserClipboard.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.pasteboard.clearContents()
                self.pasteboard.setString(self.lastUserClipboard, forType: .string)
                self.lastChangeCount = self.pasteboard.changeCount
            }
        }
    }
    
    private func setStatus(_ t: String, isBusy: Bool) { self.processingStatus = t; self.isProcessing = isBusy }
    
    // MARK: - Notifications
    private func setupNotifications() {
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