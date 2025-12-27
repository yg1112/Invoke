import Foundation
import Network

class LocalAPIServer: ObservableObject {
    static let shared = LocalAPIServer()
    
    @Published var isRunning = false
    @Published var port: UInt16 = 3000
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.fetch.api-server")
    
    func start() {
        if isRunning && listener != nil { return }
        
        // 自动注入 Cookie (如果可用)
        if !GeminiWebManager.shared.isLoggedIn {
            ChromeBridge.shared.fetchCookiesFromChrome { result in
                if case .success(let cookies) = result {
                    print("🍪 Auto-injected cookies")
                    GeminiWebManager.shared.injectRawCookies(cookies) {
                        GeminiWebManager.shared.loadGemini()
                    }
                }
            }
        }

        for tryPort in UInt16(3000)...UInt16(3010) {
            if startListener(on: tryPort) {
                self.port = tryPort
                self.isRunning = true
                print("✅ API Server on port \(tryPort)")
                return
            }
        }
    }
    
    private func startListener(on port: UInt16) -> Bool {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let newListener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            newListener.newConnectionHandler = { [weak self] conn in self?.handleConnection(conn) }
            newListener.start(queue: queue)
            self.listener = newListener
            return true
        } catch { return false }
    }
    
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveLoop(connection)
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let error = error { connection.cancel(); return }
            if let data = data, let req = String(data: data, encoding: .utf8) {
                self?.processRequest(connection, req)
                if !isComplete { self?.receiveLoop(connection) }
            } else if isComplete { connection.cancel() }
        }
    }
    
    private func processRequest(_ connection: NWConnection, _ rawRequest: String) {
        let lines = rawRequest.components(separatedBy: "\r\n")
        if lines.first?.contains("/chat/completions") == true {
            var body = ""
            if let range = rawRequest.range(of: "\r\n\r\n") { body = String(rawRequest[range.upperBound...]) }
            handleChatCompletion(connection, body)
        } else {
            let response = "HTTP/1.1 200 OK\r\nConnection: keep-alive\r\n\r\n"
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in })
        }
    }
    
    private func handleChatCompletion(_ connection: NWConnection, _ body: String) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = json["messages"] as? [[String: Any]] else { return }

        // 🔥 核心修复 1: 拼接所有上下文，而不是覆盖
        let allContent = messages.compactMap { $0["content"] as? String }.joined(separator: "\n\n")
        
        // 🔥 核心修复 2: 注入系统指令，强制忽略旧历史
        let systemInstruction = "🔴 [SYSTEM: Ignore previous history. Treat this as a NEW request.]\n\n"
        let robustPrompt = systemInstruction + allContent

        Task { @MainActor in
            // 🔥 核心修复 3: 立即发送 SSE 头，防止 Aider 超时
            let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
            connection.send(content: headers.data(using: .utf8), completion: .contentProcessed { _ in })

            do {
                try await GeminiWebManager.shared.streamAskGemini(prompt: robustPrompt) { chunk in
                    // 发送 SSE Chunk
                    let chunkID = UUID().uuidString.prefix(8)
                    let sseChunk: [String: Any] = [
                        "id": "chatcmpl-\(chunkID)",
                        "object": "chat.completion.chunk",
                        "created": Int(Date().timeIntervalSince1970),
                        "model": "gemini-2.0-flash",
                        "choices": [["index": 0, "delta": ["content": chunk], "finish_reason": NSNull()]]
                    ]
                    if let d = try? JSONSerialization.data(withJSONObject: sseChunk), let s = String(data: d, encoding: .utf8) {
                        connection.send(content: "data: \(s)\n\n".data(using: .utf8), completion: .contentProcessed{_ in})
                    }
                }
                connection.send(content: "data: [DONE]\n\n".data(using: .utf8), completion: .contentProcessed{_ in})
            } catch {
                print("❌ Error: \(error)") // 错误也要告诉 Aider
                let err = "data: {\"choices\":[{\"delta\":{\"content\":\" [Error: \(error)]\"}}]}\n\ndata: [DONE]\n\n"
                connection.send(content: err.data(using: .utf8), completion: .contentProcessed{_ in})
            }
        }
    }
}