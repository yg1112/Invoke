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
        let connID = UUID().uuidString.prefix(8)
        print("🔌 [LocalAPIServer] Connection \(connID) opened from \(connection.endpoint)")

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("   ✅ Connection \(connID) ready")
            case .failed(let error):
                print("   ❌ Connection \(connID) failed: \(error)")
            case .cancelled:
                print("   🚫 Connection \(connID) cancelled")
            default:
                break
            }
        }

        connection.start(queue: queue)

        // CRITICAL FIX: Continuously receive requests on this connection (HTTP keep-alive)
        self.receiveLoop(connection, connID: String(connID))
    }

    private func receiveLoop(_ connection: NWConnection, connID: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let error = error {
                print("   ⚠️ Connection \(connID) receive error: \(error)")
                connection.cancel()
                return
            }

            if let data = data, let req = String(data: data, encoding: .utf8) {
                print("   📥 Connection \(connID) received \(data.count) bytes")
                self?.processRequest(connection, req)

                // CRITICAL: Continue receiving on this connection (keep-alive)
                if !isComplete {
                    self?.receiveLoop(connection, connID: connID)
                } else {
                    print("   🔚 Connection \(connID) closed by client")
                    connection.cancel()
                }
            } else if isComplete {
                print("   🔚 Connection \(connID) closed (no data)")
                connection.cancel()
            } else {
                // Continue receiving
                self?.receiveLoop(connection, connID: connID)
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
            // Keep-alive: don't cancel connection after sending response
            let response = "HTTP/1.1 200 OK\r\nConnection: keep-alive\r\n\r\n"
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { error in
                if let error = error {
                    print("   ⚠️ Failed to send health check: \(error)")
                    connection.cancel()
                }
            })
        }
    }
    
    /// INVISIBLE BRIDGE: Perfect SSE streaming with OpenAI format
    private func handleChatCompletion(_ connection: NWConnection, _ body: String) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = json["messages"] as? [[String: Any]] else { return }

        let allContent = messages.compactMap { $0["content"] as? String }.joined(separator: "\n\n")

        // 加上防漂移指令，告诉 Gemini 这是一个新的无状态请求
        let systemInstruction = "🔴 [SYSTEM: This is a stateless API request. Ignore ALL previous web session history. The following text contains the FULL context (files + history + query). Treat it as a fresh start.]\n\n"

        let prompt = systemInstruction + allContent

        let stream = json["stream"] as? Bool ?? false

        Task { @MainActor in
            print("📡 [LocalAPIServer] TRUE STREAMING for: \(prompt.prefix(30))...")

            do {
                if stream {
                    // PHASE 3: Immediately send SSE headers (prevents client timeout)
                    let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
                    connection.send(content: headers.data(using: .utf8), completion: .contentProcessed { error in
                        if let error = error {
                            print("❌ Failed to send SSE headers: \(error)")
                            connection.cancel()
                        }
                    })

                    // PHASE 2: Use TRUE STREAMING with character-by-character chunks
                    try await GeminiWebManager.shared.streamAskGemini(prompt: prompt) { chunk in
                        // PHASE 3: Perfect OpenAI-compatible SSE format
                        let chunkID = UUID().uuidString.prefix(8)
                        let sseChunk: [String: Any] = [
                            "id": "chatcmpl-\(chunkID)",
                            "object": "chat.completion.chunk",
                            "created": Int(Date().timeIntervalSince1970),
                            "model": "gemini-2.0-flash",
                            "choices": [[
                                "index": 0,
                                "delta": ["content": chunk],
                                "finish_reason": NSNull()
                            ]]
                        ]

                        if let chunkData = try? JSONSerialization.data(withJSONObject: sseChunk),
                           let chunkJSON = String(data: chunkData, encoding: .utf8) {
                            let sseMessage = "data: \(chunkJSON)\n\n"
                            connection.send(content: sseMessage.data(using: .utf8), completion: .contentProcessed { _ in })
                        }
                    }

                    // Send [DONE] marker
                    let doneMessage = "data: [DONE]\n\n"
                    connection.send(content: doneMessage.data(using: .utf8), completion: .contentProcessed { error in
                        if let error = error {
                            print("   ⚠️ Failed to send [DONE]: \(error)")
                            connection.cancel()
                        } else {
                            print("   ✅ Streaming complete with [DONE]")
                        }
                    })

                } else {
                    // Non-streaming: wait for complete response
                    let responseText = try await withThrowingTaskGroup(of: String.self) { group in
                        group.addTask {
                            var fullResponse = ""
                            _ = try await GeminiWebManager.shared.streamAskGemini(prompt: prompt) { chunk in
                                fullResponse += chunk
                            }
                            return fullResponse
                        }
                        group.addTask {
                            try await Task.sleep(nanoseconds: 120 * 1_000_000_000)
                            throw URLError(.timedOut)
                        }
                        let result = try await group.next()!
                        group.cancelAll()
                        return result
                    }
                    sendJSON(connection, ["choices": [["message": ["role": "assistant", "content": responseText]]]])
                }
            } catch {
                print("❌ Streaming Error: \(error)")
                if stream {
                    let errChunk = "data: {\"choices\":[{\"delta\":{\"content\":\" [Error: \(error.localizedDescription)]\"}}]}\n\ndata: [DONE]\n\n"
                    connection.send(content: errChunk.data(using: .utf8), completion: .contentProcessed{ _ in })
                } else {
                    let errResp = "HTTP/1.1 500 Error\r\nConnection: keep-alive\r\n\r\n{\"error\": \"\(error.localizedDescription)\"}"
                    connection.send(content: errResp.data(using: .utf8), completion: .contentProcessed{ _ in })
                }
            }
        }
    }
    
    private func sendJSON(_ connection: NWConnection, _ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let jsonStr = String(data: data, encoding: .utf8) else { return }
        // Keep-alive: add Connection header and don't cancel after sending
        let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: keep-alive\r\n\r\n\(jsonStr)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { error in
            if let error = error {
                print("   ⚠️ Failed to send JSON response: \(error)")
                connection.cancel()
            }
        })
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

        // Keep-alive: don't cancel after sending (streaming mode already sent keep-alive header)
        connection.send(content: chunkData.data(using: .utf8), completion: .contentProcessed { error in
            if let error = error {
                print("   ⚠️ Failed to send stream chunk: \(error)")
                connection.cancel()
            }
        })
    }
}