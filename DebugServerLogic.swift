#!/usr/bin/env swift
import Foundation

/// DEBUG SCRIPT: Simulates LocalAPIServer logic flow
/// This demonstrates how data flows from HTTP request → GeminiWebManager → SSE response
/// Run: swift DebugServerLogic.swift

print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
print("🔍 DEBUG: LocalAPIServer Logic Flow Simulation")
print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
print("")

// ============================================================
// STEP 1: Simulate HTTP Request from Aider
// ============================================================
print("📥 STEP 1: Incoming HTTP Request (from Aider)")
print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

let rawHTTPRequest = """
POST /v1/chat/completions HTTP/1.1
Host: 127.0.0.1:3000
Content-Type: application/json

{
  "model": "gemini-2.0-flash",
  "messages": [
    {"role": "user", "content": "Write a hello world function in Python"}
  ],
  "stream": true
}
"""

print(rawHTTPRequest)
print("")

// ============================================================
// STEP 2: Parse Request (LocalAPIServer.handleChatCompletion)
// ============================================================
print("🔧 STEP 2: Parse Request Body")
print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

let bodyJSON = """
{
  "model": "gemini-2.0-flash",
  "messages": [{"role": "user", "content": "Write a hello world function in Python"}],
  "stream": true
}
"""

guard let bodyData = bodyJSON.data(using: .utf8),
      let parsedJSON = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
    print("❌ Failed to parse JSON")
    exit(1)
}

let messages = parsedJSON["messages"] as? [[String: Any]] ?? []
let isStreaming = parsedJSON["stream"] as? Bool ?? false

var extractedPrompt = ""
for msg in messages {
    if let content = msg["content"] as? String {
        extractedPrompt = content
    }
}

print("  ✅ Extracted prompt: \"\(extractedPrompt)\"")
print("  ✅ Stream mode: \(isStreaming)")
print("")

// ============================================================
// STEP 3: Immediately Send SSE Headers
// ============================================================
print("📤 STEP 3: Send SSE Headers (Immediate Response)")
print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

let sseHeaders = """
HTTP/1.1 200 OK
Content-Type: text/event-stream
Cache-Control: no-cache
Connection: keep-alive

"""

print(sseHeaders)
print("⏱️ Timestamp: <0.5s (prevents client timeout)")
print("")

// ============================================================
// STEP 4: Call GeminiWebManager.streamAskGemini
// ============================================================
print("🧠 STEP 4: Call GeminiWebManager.streamAskGemini")
print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
print("  Function signature:")
print("    streamAskGemini(prompt: \"\(extractedPrompt)\",")
print("                    isFromAider: true,")
print("                    onChunk: { chunk in ... })")
print("")
print("  Internal logic:")
print("    1. Inject prompt into Gemini Shadow Window")
print("    2. Poll response element every 100ms")
print("    3. Calculate diff: newText - oldText = chunk")
print("    4. Call onChunk(chunk) for each new character batch")
print("    5. Check isGenerating() for completion")
print("")

// ============================================================
// STEP 5: Simulate Streaming Chunks
// ============================================================
print("📡 STEP 5: Stream SSE Chunks (Character-by-Character)")
print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

// Simulate Gemini generating text incrementally
let simulatedChunks = ["def ", "hello", "_world", "():", "\n    ", "print", "(\"Hello", ", World", "!\")"]

for (index, chunk) in simulatedChunks.enumerated() {
    // Build SSE message in OpenAI format
    let chunkID = String(format: "%08x", index)
    let timestamp = Int(Date().timeIntervalSince1970)

    let sseChunk: [String: Any] = [
        "id": "chatcmpl-\(chunkID)",
        "object": "chat.completion.chunk",
        "created": timestamp,
        "model": "gemini-2.0-flash",
        "choices": [[
            "index": 0,
            "delta": ["content": chunk],
            "finish_reason": NSNull()
        ]]
    ]

    if let chunkData = try? JSONSerialization.data(withJSONObject: sseChunk),
       let chunkJSON = String(data: chunkData, encoding: .utf8) {
        print("data: \(chunkJSON)")
        print("")
    }

    // Simulate 100ms delay
    usleep(100_000)
}

// ============================================================
// STEP 6: Send [DONE] Marker
// ============================================================
print("✅ STEP 6: Send [DONE] Marker")
print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
print("data: [DONE]")
print("")

// ============================================================
// SUMMARY
// ============================================================
print("")
print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
print("📊 SUMMARY: Data Flow Verification")
print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
print("")
print("✅ HTTP Request → Parsed correctly")
print("✅ SSE Headers → Sent immediately (<0.5s)")
print("✅ streamAskGemini → Would be called with onChunk callback")
print("✅ Each chunk → Wrapped in OpenAI-compatible SSE format")
print("✅ [DONE] marker → Sent at end")
print("")
print("🎯 Key Logic Points:")
print("  1. LocalAPIServer does NOT call webManager directly")
print("  2. It calls GeminiWebManager.shared.streamAskGemini()")
print("  3. onChunk callback fires for EACH character batch")
print("  4. Each chunk is individually sent as SSE message")
print("  5. No buffering - true real-time streaming")
print("")
print("📍 Critical Files:")
print("  • LocalAPIServer.swift:127-173 - Main handler")
print("  • GeminiWebManager.swift:157-207 - streamAskGemini implementation")
print("")
print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
