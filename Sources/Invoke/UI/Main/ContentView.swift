import SwiftUI

struct ContentView: View {
    @StateObject private var bridgeService = BridgeService.shared
    @StateObject private var aiderService = AiderService.shared
    // 注意：移除了 WebManager 和 LinkLogic，只保留纯净的 UI
    
    @State private var inputText = ""
    @State private var projectPath = UserDefaults.standard.string(forKey: "ProjectRoot") ?? ""
    @State private var isAlwaysOnTop = true

    // 🎨 Colors
    let neonGreen = Color(red: 0.0, green: 0.9, blue: 0.5)
    let neonBlue = Color(red: 0.0, green: 0.5, blue: 1.0)
    let neonOrange = Color(red: 1.0, green: 0.6, blue: 0.0)
    let dangerRed = Color(red: 1.0, green: 0.3, blue: 0.4)

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.05, blue: 0.07).opacity(0.95).edgesIgnoringSafeArea(.all)
            VStack(spacing: 0) {
                // Header
                HStack(spacing: 12) {
                    Circle().fill(bridgeService.isLoggedIn ? neonGreen : dangerRed).frame(width: 8, height: 8)
                    Text(bridgeService.connectionStatus).font(.caption).foregroundColor(.gray)
                    if !bridgeService.isLoggedIn {
                        Button("Login") { bridgeService.showLoginWindow() }
                            .buttonStyle(.borderedProminent).tint(neonOrange)
                    }
                    Spacer()
                    Button("Restart Bridge") { bridgeService.startBridge() }.buttonStyle(.plain)
                    Button(isAlwaysOnTop ? "Pin 📌" : "Pin") { toggleAlwaysOnTop() }.buttonStyle(.plain)
                }.padding()
                
                // Content
                if projectPath.isEmpty {
                    VStack {
                        Image(systemName: "bird.fill").font(.largeTitle).foregroundColor(neonOrange)
                        Button("Select Project Folder") { selectProject() }
                    }.frame(maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading) {
                            ForEach(aiderService.messages) { msg in
                                ChatBubble(message: msg, neonBlue: neonBlue)
                            }
                        }.padding()
                    }
                }
                
                // Input
                if !projectPath.isEmpty {
                    HStack {
                        TextField("Instruct Aider...", text: $inputText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { sendMessage() }
                        Button(action: sendMessage) { Image(systemName: "paperplane.fill") }
                    }.padding()
                }
            }
        }
        .frame(minWidth: 480, minHeight: 400)
        .onAppear {
            toggleAlwaysOnTop()
            // 启动 Server (在此处安全启动，或手动启动)
            LocalAPIServer.shared.start() 
            bridgeService.startBridge()
            if !projectPath.isEmpty { aiderService.startAider(projectPath: projectPath) }
        }
    }
    
    private func selectProject() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            self.projectPath = url.path
            UserDefaults.standard.set(url.path, forKey: "ProjectRoot")
            aiderService.startAider(projectPath: url.path)
        }
    }
    
    private func sendMessage() {
        guard !inputText.isEmpty else { return }
        aiderService.sendUserMessage(inputText)
        inputText = ""
    }
    
    private func toggleAlwaysOnTop() {
        if let panel = NSApplication.shared.windows.first {
            isAlwaysOnTop.toggle()
            panel.level = isAlwaysOnTop ? .floating : .normal
        }
    }
}

struct ChatBubble: View {
    let message: AiderService.ChatMessage
    let neonBlue: Color
    var body: some View {
        HStack {
            if message.isUser {
                Spacer(); Text(message.content).padding(8).background(neonBlue).cornerRadius(8)
            } else {
                Text(message.content).padding(8).background(Color.white.opacity(0.1)).cornerRadius(8).textSelection(.enabled); Spacer()
            }
        }
    }
}