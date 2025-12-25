import Foundation

class GitService {
    static let shared = GitService()
    
    private init() {}
    
    func run(args: [String], in directory: String) throws -> String {
        let task = Process()
        let pipe = Pipe()
        let errorPipe = Pipe()
        
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = args
        task.currentDirectoryURL = URL(fileURLWithPath: directory)
        task.standardOutput = pipe
        task.standardError = errorPipe
        
        // Environment for non-interactive
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0" 
        task.environment = env
        
        try task.run()
        task.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        
        if task.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8) ?? "Unknown Git Error"
            // Ignore minor warnings
            if errorOutput.contains("switched to branch") || errorOutput.contains("up to date") {
                return output 
            }
            throw NSError(domain: "GitError", code: Int(task.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errorOutput])
        }
        
        return output
    }
    
    func getCommitURL(for hash: String, in directory: String) -> String? {
        guard let remote = try? run(args: ["config", "--get", "remote.origin.url"], in: directory) else { return nil }
        
        // Clean up SSH or HTTPS URL to web URL
        let remoteURL = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if remoteURL.isEmpty { return nil }
        
        // Fix: Use let instead of var for immutable
        let url = remoteURL
            .replacingOccurrences(of: "git@github.com:", with: "https://github.com/")
            .replacingOccurrences(of: ".git", with: "")
        
        return "\(url)/commit/\(hash)"
    }
    
    func commitChanges(in directory: String, message: String) throws -> String {
        // 1. Add all changes
        _ = try run(args: ["add", "."], in: directory)
        
        // 2. Commit
        return try run(args: ["commit", "-m", message], in: directory)
    }
    
    func pushToRemote(in directory: String) throws {
        try? configureCredentialHelper(in: directory)
        _ = try run(args: ["push"], in: directory)
    }
    
    func createBranch(in directory: String, name: String) throws {
        // Check if branch exists
        if let _ = try? run(args: ["rev-parse", "--verify", name], in: directory) {
            _ = try run(args: ["checkout", name], in: directory)
        } else {
            _ = try run(args: ["checkout", "-b", name], in: directory)
        }
    }
    
    func pushBranch(in directory: String, branch: String) throws -> String {
        try? configureCredentialHelper(in: directory)
        return try run(args: ["push", "-u", "origin", branch], in: directory)
    }
    
    func deleteBranch(in directory: String, branch: String) {
        // Switch to main first
        _ = try? run(args: ["checkout", "main"], in: directory)
        _ = try? run(args: ["branch", "-D", branch], in: directory)
    }
    
    private func configureCredentialHelper(in directory: String) throws {
        // Fix: Silence unused result warnings
        _ = try? run(args: ["config", "credential.helper", "osxkeychain"], in: directory)
        _ = try? run(args: ["config", "--global", "credential.helper", "cache --timeout=3600"], in: directory)
    }
    
    // MARK: - Auto Push (Aider Integration)
    
    func autoPushChanges(in directory: String, message: String = "refactor: Auto-update by Fetch/Aider") {
        DispatchQueue.global().async {
            do {
                _ = try self.run(args: ["add", "."], in: directory)
                _ = try self.run(args: ["commit", "-m", message], in: directory)
                _ = try self.run(args: ["push", "origin", "main"], in: directory)
                print("🚀 Auto-pushed changes to GitHub")
            } catch {
                print("⚠️ Auto-push failed: \(error)")
            }
        }
    }
}