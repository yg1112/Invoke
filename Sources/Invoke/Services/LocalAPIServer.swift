import Foundation
import Network

/// 本地 API Server (Fixed: Immediate Headers for Streaming)
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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            if let data = data, let req = String(data: data, encoding: .utf8) {
                self?.processRequest(connection, req)
            } else {
                connection.cancel()
            }
        }
    }
    
    private func processRequest(_ connection: NWConnection, _ rawRequest: String) {
        let lines = rawRequest.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return }
        
        let path = String(parts[1])
        var body = ""
        if let range = rawRequest.range(of: "\r\n\r\n") {
            body = String(rawRequest[range.upperBound...])
        }
        
        if path.contains("/chat/completions") {
            handleChatCompletion(connection, body)
        } else {
            let response = "HTTP/1.1 200 OK\r\n\r\n"
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
    
    private func handleChatCompletion(_ connection: NWConnection, _ body: String) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = json["messages"] as? [[String: Any]] else { return }
        
        var prompt = ""
        for msg in messages {
            if let content = msg["content"] as? String { prompt = content }
        }
        
        let stream = json["stream"] as? Bool ?? false
        
        Task {
            do {
                if stream {
                    // 1. 关键修复：立即发送 Header，防止客户端超时
                    let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
                    connection.send(content: headers.data(using: .utf8), completion: .contentProcessed { error in
                        if let error = error {
                            print("❌ Failed to send headers: \(error)")
                            connection.cancel()
                        }
                    })
                }
                
                // 2. 执行耗时操作
                // 增加超时控制 (60秒)
                let responseText = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask {
                        return try await GeminiWebManager.shared.askGemini(prompt: prompt, isFromAider: true)
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                        throw URLError(.timedOut)
                    }
                    let result = try await group.next()!
                    group.cancelAll()
                    return result
                }
                
                if stream {
                    // 3. 发送实际内容（Header 已发送，只发送数据）
                    sendStreamChunk(connection, text: responseText)
                } else {
                    sendJSON(connection, ["choices": [["message": ["role": "assistant", "content": responseText]]]])
                }
            } catch {
                print("❌ Generation Error: \(error)")
                // 如果已经发送了 Header (Stream 模式)，我们不能再发 500 了，只能断开
                if !stream {
                    let errResp = "HTTP/1.1 500 Error\r\n\r\n{\"error\": \"\(error.localizedDescription)\"}"
                    connection.send(content: errResp.data(using: .utf8), completion: .contentProcessed{ _ in connection.cancel() })
                } else {
                    // Stream 模式下发生错误，发送一个错误提示作为内容，或者直接断开
                    let errChunk = "data: {\"choices\":[{\"delta\":{\"content\":\" [Error: \(error.localizedDescription)]\"}}]}\n\ndata: [DONE]\n\n"
                    connection.send(content: errChunk.data(using: .utf8), completion: .contentProcessed{ _ in connection.cancel() })
                }
            }
        }
    }
    
    private func sendJSON(_ connection: NWConnection, _ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let jsonStr = String(data: data, encoding: .utf8) else { return }
        let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n\(jsonStr)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
    
    private func sendStreamChunk(_ connection: NWConnection, text: String) {
        // 注意：这里不再发送 Header，只发送 data
        var chunkData = ""
        let chunk = ["choices": [["delta": ["content": text]]]]
        if let data = try? JSONSerialization.data(withJSONObject: chunk),
           let jsonStr = String(data: data, encoding: .utf8) {
            chunkData += "data: \(jsonStr)\n\n"
        }
        chunkData += "data: [DONE]\n\n"
        
        connection.send(content: chunkData.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}