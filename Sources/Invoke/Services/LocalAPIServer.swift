import Foundation
import Network

/// 本地 OpenAI 兼容 API 服务器
/// 负责将 Aider 的请求转发给 Gemini
class LocalAPIServer: ObservableObject {
    static let shared = LocalAPIServer()
    
    @Published var isRunning = false
    @Published var port: UInt16 = 3000
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.fetch.api-server")
    
    func start() {
        // 防止重复启动
        if isRunning && listener != nil { return }
        
        // 尝试端口范围 3000-3010
        for tryPort in UInt16(3000)...UInt16(3010) {
            if startListener(on: tryPort) {
                self.port = tryPort
                self.isRunning = true
                print("✅ Local API Server running on port \(tryPort)")
                return
            }
        }
        print("❌ Failed to start API Server on ports 3000-3010")
    }
    
    private func startListener(on port: UInt16) -> Bool {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            
            let newListener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            
            newListener.stateUpdateHandler = { state in
                switch state {
                case .failed(let error):
                    print("API Listener error: \(error)")
                default: break
                }
            }
            
            newListener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            
            newListener.start(queue: queue)
            self.listener = newListener
            return true
        } catch {
            return false
        }
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }
    
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection)
    }
    
    private func receiveRequest(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty, let requestStr = String(data: data, encoding: .utf8) {
                self?.processRequest(connection, requestStr)
            } else if let error = error {
                connection.cancel()
            }
        }
    }
    
    private func processRequest(_ connection: NWConnection, _ rawRequest: String) {
        // 简单的 HTTP 解析
        let lines = rawRequest.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return }
        
        let method = String(parts[0])
        let path = String(parts[1])
        
        // 提取 Body
        var body = ""
        if let range = rawRequest.range(of: "\r\n\r\n") {
            body = String(rawRequest[range.upperBound...])
        }
        
        // 路由逻辑
        if method == "POST" && path.contains("/chat/completions") {
            handleChatCompletion(connection, body)
        } else if method == "GET" && path.contains("/models") {
            sendJSON(connection, ["data": [["id": "gemini-2.0-flash", "object": "model"]]])
        } else {
            // 默认响应 200 OK (OPTIONS 请求等)
            sendOK(connection)
        }
    }
    
    private func handleChatCompletion(_ connection: NWConnection, _ body: String) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = json["messages"] as? [[String: Any]] else {
            sendError(connection, 400)
            return
        }
        
        // 提取最后的 Prompt
        var lastPrompt = ""
        for msg in messages {
            if let content = msg["content"] as? String, let role = msg["role"] as? String {
                if role == "user" { lastPrompt = content }
                if role == "system" { lastPrompt = "System: \(content)\n" + lastPrompt }
            }
        }
        
        let stream = json["stream"] as? Bool ?? false
        
        Task {
            // 调用 Gemini (通过 BridgeService/WebManager)
            do {
                let responseText = try await GeminiWebManager.shared.askGemini(prompt: lastPrompt)
                
                if stream {
                    sendStreamResponse(connection, text: responseText)
                } else {
                    sendJSON(connection, [
                        "choices": [
                            ["message": ["role": "assistant", "content": responseText]]
                        ]
                    ])
                }
            } catch {
                sendError(connection, 500)
            }
        }
    }
    
    private func sendStreamResponse(_ connection: NWConnection, text: String) {
        var response = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n"
        
        // 模拟流式输出
        let chunk = [
            "choices": [
                ["delta": ["content": text]]
            ]
        ]
        
        if let data = try? JSONSerialization.data(withJSONObject: chunk),
           let jsonStr = String(data: data, encoding: .utf8) {
            response += "data: \(jsonStr)\n\n"
        }
        response += "data: [DONE]\n\n"
        
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
    
    private func sendJSON(_ connection: NWConnection, _ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let jsonStr = String(data: data, encoding: .utf8) else { return }
        
        let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n\(jsonStr)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
    
    private func sendOK(_ connection: NWConnection) {
        let response = "HTTP/1.1 200 OK\r\n\r\n"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
    
    private func sendError(_ connection: NWConnection, _ code: Int) {
        let response = "HTTP/1.1 \(code) Error\r\n\r\n"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}