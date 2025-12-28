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
        for tryPort in UInt16(3000)...UInt16(3010) {
            if startListener(on: tryPort) {
                self.port = tryPort; self.isRunning = true
                print("✅ API Server listening on port \(tryPort)")
                return
            }
        }
    }
    
    private func startListener(on port: UInt16) -> Bool {
        do {
            let params = NWParameters.tcp; params.allowLocalEndpointReuse = true
            let newListener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            newListener.newConnectionHandler = { [weak self] conn in self?.handleConnection(conn) }
            newListener.start(queue: queue); self.listener = newListener
            return true
        } catch { return false }
    }
    
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue); receiveLoop(connection)
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if error != nil { connection.cancel(); return }
            if let data = data, let req = String(data: data, encoding: .utf8) {
                self?.processRequest(connection, req)
                if !isComplete { self?.receiveLoop(connection) }
            } else if isComplete { connection.cancel() }
        }
    }
    
    private func processRequest(_ connection: NWConnection, _ rawRequest: String) {
        let lines = rawRequest.components(separatedBy: "\r\n")
        if lines.first?.contains("/chat/completions") == true {
            var body = ""; if let range = rawRequest.range(of: "\r\n\r\n") { body = String(rawRequest[range.upperBound...]) }
            handleChatCompletion(connection, body)
        } else {
            let response = "HTTP/1.1 200 OK\r\nConnection: keep-alive\r\n\r\n"
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in })
        }
    }
    
    private func handleChatCompletion(_ connection: NWConnection, _ body: String) {
        print("📨 Received Request from Aider...") 
        
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = json["messages"] as? [[String: Any]] else {
            print("❌ Failed to parse request body")
            return
        }

        let allContent = messages.compactMap { $0["content"] as? String }.joined(separator: "\n\n")
        
        // 🍎 Woz's "Social Engineering" Prompt
        // 既然是 Invisible Bridge，我们就假装是用户在跟它说话，而不是系统在下命令。
        let systemInstruction = """
        [USER SESSION START]
        Hi Gemini! I am working on a coding task using Aider.
        Please look at the file content provided below and output the necessary changes.
        
        STYLE RULES:
        1. Use the standard Aider `<<<<<<< SEARCH` and `>>>>>>> REPLACE` blocks.
        2. Do NOT wrap the output in JSON. Plain text is best.
        3. Be concise. Start directly with the code changes if possible.
        
        INPUT DATA:
        """
        
        let robustPrompt = systemInstruction + "\n\n" + allContent

        let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n"
        connection.send(content: headers.data(using: .utf8), completion: .contentProcessed{_ in})

        Task.detached {
            print("⏳ Asking Gemini (Raw Mode)...")
            self.sendSSEChunk(connection, content: "🧠 Woz's Logic: Connecting...")

            var fullBuffer = ""
            var lastHeartbeat = Date()
            let stream = await GeminiCore.shared.generate(prompt: robustPrompt)

            let heartbeatTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if Date().timeIntervalSince(lastHeartbeat) > 2 {
                        self.sendSSEChunk(connection, content: ".")
                    }
                }
            }

            for await chunk in stream {
                fullBuffer += chunk
                lastHeartbeat = Date()
            }

            heartbeatTask.cancel()
            print("✅ Gemini Response Complete. Length: \(fullBuffer.count)")

            // 🔥 Passthrough Strategy
            // 不要解析 JSON，直接把文本丢给 Aider。
            // 唯一需要做的是防止 Gemini 把所有内容包在 ```markdown 里面
            let outputToSend = self.cleanRawOutput(fullBuffer)

            self.sendSSEChunk(connection, content: outputToSend)
            connection.send(content: "data: [DONE]\n\n".data(using: .utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
    
    // SSE 发送辅助方法
    private func sendSSEChunk(_ connection: NWConnection, content: String) {
        let responseJson = ["choices": [["delta": ["content": content]]]]
        if let data = try? JSONEncoder().encode(responseJson),
           let str = String(data: data, encoding: .utf8) {
            let sse = "data: \(str)\n\n"
            connection.send(content: sse.data(using: .utf8), completion: .contentProcessed{_ in})
        }
    }

    // Woz 的极简清洗器
    private func cleanRawOutput(_ raw: String) -> String {
        var clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 很多时候 Gemini 会说 "Here is the code:\n```..."
        // 我们尝试去掉开头的废话，只保留 SEARCH 块
        if clean.contains("<<<<<<< SEARCH") {
            // 如果找到了 SEARCH 块，这才是我们关心的核心
            // 但有时候前面会有文件名解释，所以我们不能无脑切。
            // 考虑到 Aider 能够处理 mixed text，我们主要处理 Markdown Code Fence 的干扰。
            
            // 如果整个回答被 ``` 包裹，去掉首尾的 ```
            if clean.hasPrefix("```") && clean.hasSuffix("```") {
                let lines = clean.components(separatedBy: .newlines)
                if lines.count >= 2 {
                    // 去掉第一行 (```) 和最后一行 (```)
                    clean = lines.dropFirst().dropLast().joined(separator: "\n")
                }
            }
        }
        
        return clean
    }
}