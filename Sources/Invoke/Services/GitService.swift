import Foundation

class GitService {
    static let shared = GitService()
    
    /// 在指定目录下执行 Git 命令
    func run(args: [String], in directory: String) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = args
        task.currentDirectoryURL = URL(fileURLWithPath: directory)
        
        // 🔑 配置环境变量
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_ASKPASS"] = ""
        task.environment = env
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        
        try task.run()
        task.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        
        if task.terminationStatus != 0 {
            throw NSError(domain: "GitError", code: Int(task.terminationStatus), userInfo: [NSLocalizedDescriptionKey: output])
        }
        
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // ... (commitChanges, pushToRemote, createBranch, pushBranch 保持不变)
    
    func commitChanges(in directory: String, message: String) throws {
        _ = try run(args: ["add", "."], in: directory)
        _ = try run(args: ["commit", "-m", message], in: directory)
    }
    
    func pushToRemote(in directory: String) throws {
        try? configureCredentialHelper(in: directory)
        _ = try run(args: ["push"], in: directory)
    }
    
    func createBranch(in directory: String, name: String) throws {
        _ = try run(args: ["checkout", "-b", name], in: directory)
    }
    
    func pushBranch(in directory: String, branch: String) throws {
        try? configureCredentialHelper(in: directory)
        _ = try run(args: ["push", "-u", "origin", branch], in: directory)
    }
    
    // MARK: - NEW: Branch Cleanup
    
    /// 删除分支 (本地 + 远程)
    func deleteBranch(in directory: String, branch: String) {
        // 1. 切回 main 防止无法删除当前分支
        _ = try? run(args: ["checkout", "main"], in: directory)
        _ = try? run(args: ["checkout", "master"], in: directory)
        
        // 2. 删除本地分支
        _ = try? run(args: ["branch", "-D", branch], in: directory)
        
        // 3. 删除远程分支
        try? configureCredentialHelper(in: directory)
        _ = try? run(args: ["push", "origin", "--delete", branch], in: directory)
    }
    
    // ... (Helper methods keep same)
    
    private func configureCredentialHelper(in directory: String) throws {
        try? run(args: ["config", "credential.helper", "osxkeychain"], in: directory)
        try? run(args: ["config", "--global", "credential.helper", "cache --timeout=3600"], in: directory)
    }
    
    func getRemoteURL(in directory: String) -> String? {
        guard let remoteURL = try? run(args: ["config", "--get", "remote.origin.url"], in: directory) else {
            return nil
        }
        var url = remoteURL
            .replacingOccurrences(of: "git@github.com:", with: "https://github.com/")
            .replacingOccurrences(of: ".git", with: "")
        return url
    }
    
    func getCommitURL(for hash: String, in directory: String) -> String? {
        guard let baseURL = getRemoteURL(in: directory) else { return nil }
        return "\(baseURL)/commit/\(hash)"
    }
}