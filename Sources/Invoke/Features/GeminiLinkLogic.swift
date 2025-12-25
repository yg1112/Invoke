import SwiftUI
import Combine
import AppKit

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

```
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

// 🛡️ 安全拆分定义 (防止 Parser 误读)
private let magicHeader = ">>>" + " INVOKE"
private let fileHeader = ">>>" + " FILE:"
private let searchStart = "<<<<<<<" + " SEARCH"
private let replaceEnd = ">>>>>>>" + " REPLACE"
private let newFileStart = "<<<" + "FILE>>>"
private let newFileEnd = "<<<" + "END>>>"

init() {
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
    
    // 🛑 防误触
    let ignoreSig = "[System Instruction: " + "Fetch App Protocol]"
    if content.contains(ignoreSig) { return }
    if content.contains("[Fetch Review Request]") { return }
    
    // 🔒 安全锁
    guard content.contains(magicHeader) else {
        if !content.contains("@code") { lastUserClipboard = content }
        return
    }
    
    print("⚡️ Detected Protocol Content")
    processAllChanges(content)
}

private func processAllChanges(_ rawText: String) {
    restoreUserClipboardImmediately()
    setStatus("Processing...", isBusy: true)
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        guard let self = self else { return }
        let text = rawText.replacingOccurrences(of: "\r\n", with: "\n")
        var modified: Set<String> = []
        
        // Parsers
        let fullFiles = self.parseFull(text)
        for f in fullFiles { if self.writeFile(f.path, f.content) { modified.insert(f.path) } }
        
        let smartEdits = self.parseSmart(text)
        for f in smartEdits {
            let res = self.applyPatches(f.path, f.content)
            if res.modified { modified.insert(f.path) }
        }
        
        self.finalize(Array(modified))
    }
}

private func parseFull(_ text: String) -> [FilePayload] {
    // 构造正则时使用变量，避免源码中出现完整标记
    let p = "(?s)" + newFileStart + "\\s*([^\\n]+)\\n(.*?)\\n" + newFileEnd
    let regex = try! NSRegularExpression(pattern: p)
    let matches = regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
    return matches.compactMap { m -> FilePayload? in
        guard let r1 = Range(m.range(at: 1), in: text), let r2 = Range(m.range(at: 2), in: text) else { return nil }
        var c = String(text[r2])
        if c.hasPrefix("```") { c = c.replacingOccurrences(of: "^```\\w*\\n", with: "", options: .regularExpression).replacingOccurrences(of: "\n```$", with: "", options: .regularExpression) }
        return FilePayload(path: String(text[r1]).trimmingCharacters(in: .whitespacesAndNewlines), content: c)
    }
}

private func parseSmart(_ text: String) -> [FilePayload] {
    return text.components(separatedBy: ">>> FILE").compactMap { block -> FilePayload? in
        let lines = block.components(separatedBy: .newlines)
        var p = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if p.hasPrefix(":") { p.removeFirst() }
        p = p.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, !p.contains("<<<"), block.contains(searchStart) else { return nil }
        return FilePayload(path: p, content: lines.dropFirst().joined(separator: "\n"))
    }
}

private func applyPatches(_ path: String, _ patch: String) -> (modified: Bool, perfect: Bool) {
    let url = URL(fileURLWithPath: projectRoot).appendingPathComponent(path)
    guard let d = try? Data(contentsOf: url), var content = String(data: d, encoding: .utf8) else { return (false, false) }
    
    let p = "(?s)" + searchStart + "\\s*\\n(.*?)\\n=======\\s*\\n(.*?)\\n" + replaceEnd
    let regex = try! NSRegularExpression(pattern: p)
    let matches = regex.matches(in: patch, range: NSRange(patch.startIndex..<patch.endIndex, in: patch))
    var mod = false
    
    for m in matches.reversed() {
        guard let r1 = Range(m.range(at: 1), in: patch), let r2 = Range(m.range(at: 2), in: patch) else { continue }
        var search = String(patch[r1])
        let replace = String(patch[r2])
        if search.hasPrefix("```") { search = search.replacingOccurrences(of: "```", with: "") }
        
        if let r = content.range(of: search) { content.replaceSubrange(r, with: replace); mod = true; continue }
        if let r = fuzzyMatch(search, content) { content.replaceSubrange(r, with: replace); mod = true; continue }
        if let r = tokenMatch(search, content) { content.replaceSubrange(r, with: replace); mod = true; continue }
        if let r = logicMatch(search, content) { content.replaceSubrange(r, with: replace); mod = true; continue }
    }
    if mod { _ = writeFile(path, content) }
    return (mod, true)
}

private func fuzzyMatch(_ s: String, _ c: String) -> Range<String.Index>? {
    let p = s.components(separatedBy: .newlines).map { NSRegularExpression.escapedPattern(for: $0.trimmingCharacters(in: .whitespaces)) }.joined(separator: "\\s*\\n\\s*")
    return c.range(of: p, options: .regularExpression)
}
private func tokenMatch(_ s: String, _ c: String) -> Range<String.Index>? {
    let p = s.components(separatedBy: .whitespacesAndNewlines).filter{!$0.isEmpty}.map{NSRegularExpression.escapedPattern(for: $0)}.joined(separator: "[\\s\\n]+")
    return c.range(of: p, options: .regularExpression)
}
private func logicMatch(_ s: String, _ c: String) -> Range<String.Index>? {
    let clean = stripComments(s)
    let p = clean.components(separatedBy: .whitespacesAndNewlines).filter{!$0.isEmpty}.map{NSRegularExpression.escapedPattern(for: $0)}.joined(separator: "(?:\\s|//[^\\n]*|/\\*[\\s\\S]*?\\*/)+")
    return c.range(of: p, options: .regularExpression)
}
private func stripComments(_ t: String) -> String {
    return t.replacingOccurrences(of: "//.*", with: "", options: .regularExpression).replacingOccurrences(of: "/\\*[\\s\\S]*?\\*/", with: "", options: .regularExpression)
}

private func writeFile(_ path: String, _ content: String) -> Bool {
    let url = URL(fileURLWithPath: projectRoot).appendingPathComponent(path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? content.write(to: url, atomically: true, encoding: .utf8)
    return true
}

private func finalize(_ files: [String]) {
    DispatchQueue.main.async {
        if files.isEmpty { self.setStatus("", isBusy: false); return }
        let summary = "Update: \(files.map{URL(fileURLWithPath: $0).lastPathComponent}.joined(separator: ", "))"
        self.setStatus("Committing...", isBusy: true)
        self.commitAndPush(summary)
    }
}

private func commitAndPush(_ msg: String) {
    DispatchQueue.global().async {
        _ = try? GitService.shared.commitChanges(in: self.projectRoot, message: msg)
        let hash = (try? GitService.shared.run(args: ["rev-parse", "--short", "HEAD"], in: self.projectRoot)) ?? "done"
        if self.gitMode == .yolo { _ = try? GitService.shared.pushToRemote(in: self.projectRoot) }
        else if self.gitMode == .safe {
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
    // 🔥 这里是核心修正：使用变量插值来生成 Prompt，而不是直接写死字符串
    // 这样剪贴板里的源码本身就不会包含完整的标记
    let header = "[System Instruction: " + "Fetch App Protocol]"
    
    let text = """
    \(header)
    
    ⚠️ CRITICAL: Start response with:
    >>> INVOKE
    
    FORMAT A (New):
    \(newFileStart) path/file
    content
    \(newFileEnd)
    
    FORMAT B (Edit):
    >>> FILE: path/file
    \(searchStart)
    (Exact match)
    =======
    (New code)
    \(replaceEnd)
    """
    pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
    showNotification("System Prompt Copied", "Paste to Gemini")
}

func manualApplyFromClipboard() { checkClipboard() }

func reviewLastChange() {
    guard let log = changeLogs.first else { return }
    setStatus("Fetching Diff...", isBusy: true)
    DispatchQueue.global().async {
        let diff = (try? GitService.shared.run(args: ["show", log.commitHash], in: self.projectRoot)) ?? ""
        let p = """
        [Fetch Review Request]
        Check this commit (\(log.commitHash)):
        \(diff)
        If bug found, FIX with >>> INVOKE.
        """
        DispatchQueue.main.async {
            self.setStatus("", isBusy: false)
            self.pasteboard.clearContents(); self.pasteboard.setString(p, forType: .string)
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
            self.pasteboard.clearContents(); self.pasteboard.setString(self.lastUserClipboard, forType: .string)
            self.lastChangeCount = self.pasteboard.changeCount
        }
    }
}

private func setStatus(_ t: String, isBusy: Bool) { self.processingStatus = t; self.isProcessing = isBusy }
private func showNotification(_ t: String, _ b: String) {
    let n = NSUserNotification(); n.title = t; n.informativeText = b; NSUserNotificationCenter.default.deliver(n)
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

```

}