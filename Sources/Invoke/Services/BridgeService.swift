import Foundation

class BridgeService: ObservableObject {
    static let shared = BridgeService()
    private var process: Process?
    @Published var isRunning = false
    @Published var connectionStatus = "Disconnected"
    
    private var healthCheckTimer: Timer?

    // 开发环境：指向 gemini-bridge 源码目录
    private let bridgeScriptPath = "/Users/yukungao/github/Fetch/gemini-bridge/proxy.py"

    func startBridge() {
        guard !isRunning else { return }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [bridgeScriptPath]
        process.currentDirectoryURL = URL(fileURLWithPath: bridgeScriptPath).deletingLastPathComponent()
        
        // 管道处理日志
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.connectionStatus = "Bridge Stopped"
                self?.stopHealthCheck()
            }
        }

        do {
            try process.run()
            self.process = process
            self.isRunning = true
            self.connectionStatus = "Bridge Running (Port 3000)"
            
            // 启动健康检查轮询
            startHealthCheck()
        } catch {
            print("Failed to start bridge: \(error)")
            self.connectionStatus = "Start Failed"
        }
    }

    func stopBridge() {
        process?.terminate()
        process = nil
        isRunning = false
        stopHealthCheck()
    }
    
    private func startHealthCheck() {
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard self?.isRunning == true else { return }
            self?.checkHealth()
        }
    }
    
    private func stopHealthCheck() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
    }
    
    private func checkHealth() {
        guard let url = URL(string: "http://localhost:3000/v1/health") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] _, response, _ in
            DispatchQueue.main.async {
                if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                    self?.connectionStatus = "🟢 Bridge Connected"
                } else {
                    self?.connectionStatus = "🔴 Bridge Unreachable"
                }
            }
        }.resume()
    }
}

