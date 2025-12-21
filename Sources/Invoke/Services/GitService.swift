import Foundation

class GitService {
    static let shared = GitService()
    
    /// 在指定目录下执行 Git 命令
    func run(args: [String], in directory: String) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = args
        task.currentDirectoryURL = URL(fileURLWithPath: directory)
        
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
    
    func pushChanges(in directory: String, message: String) throws -> String {
        _ = try run(args: ["add", "."], in: directory)
        _ = try run(args: ["commit", "-m", message], in: directory)
        let pushResult = try run(args: ["push"], in: directory)
        return "Committed & Pushed: \(message)\n\(pushResult)"
    }
    
    func getDiff(in directory: String) -> String {
        // 获取未暂存和已暂存的差异
        let diff = (try? run(args: ["diff"], in: directory)) ?? ""
        let cachedDiff = (try? run(args: ["diff", "--cached"], in: directory)) ?? ""
        return diff + "\n" + cachedDiff
    }
}
