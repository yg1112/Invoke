import Foundation

/// INVISIBLE BRIDGE: Minimal stub - Aider handles all Git operations
class GitService {
    static let shared = GitService()
    private init() {}

    // Stub for any legacy code that might call this
    func run(args: [String], in directory: String) throws -> String {
        throw NSError(domain: "GitError", code: -1,
                     userInfo: [NSLocalizedDescriptionKey: "Git operations disabled - Aider handles all Git"])
    }
}
