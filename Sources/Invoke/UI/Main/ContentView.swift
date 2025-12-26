import SwiftUI
import ApplicationServices

struct ContentView: View {
    @StateObject private var bridgeService = BridgeService.shared
    @StateObject private var aiderService = AiderService.shared
    @StateObject private var webManager = GeminiWebManager.shared
    private let linkLogic = GeminiLinkLogic.shared
    @State private var inputText = ""
    @State private var projectPath = UserDefaults.standard.string(forKey: "ProjectRoot") ?? ""
@State private var isAlwaysOnTop = true

// 🎨 Fetch Palette
let darkBg = Color(red: 0.05, green: 0.05, blue: 0.07)
let neonGreen = Color(red: 0.0, green: 0.9, blue: 0.5)
let neonBlue = Color(red: 0.0, green: 0.5, blue: 1.0)
let neonOrange = Color(red: 1.0, green: 0.6, blue: 0.0)
let dangerRed = Color(red: 1.0, green: 0.3, blue: 0.4)

var body: some View {
    ZStack {
        darkBg.opacity(0.95).edgesIgnoringSafeArea(.all)
        
        RoundedRectangle(cornerRadius: 16)
            .strokeBorder(
                LinearGradient(
                    colors: [Color.white.opacity(0.1), Color.white.opacity(0.02)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
        
        VStack(spacing: 0) {
                // === HUD HEADER ===
                headerView
                
                // === CONTENT ===
                if projectPath.isEmpty {
                    projectSetupView
                } else {
                    chatView
                }
                
                // === INPUT AREA ===
                if !projectPath.isEmpty {
                    inputAreaView
                }
            }
        }
        .frame(minWidth: 480, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
        .cornerRadius(16)
        .onAppear {
            toggleAlwaysOnTop()
            // App 启动时自动启动 Bridge
            bridgeService.startBridge()
            
            // 确保 GeminiLinkLogic 的项目根目录已设置（触发监听启动）
            if !projectPath.isEmpty && linkLogic.projectRoot != projectPath {
                linkLogic.projectRoot = projectPath
            } else if !projectPath.isEmpty && !linkLogic.isListening {
                // 如果项目根目录已设置但监听未启动，手动启动
                linkLogic.startListening()
            }
            
            // 如果已有 projectPath，启动 Aider
            if !projectPath.isEmpty {
                aiderService.startAider(projectPath: projectPath)
            }
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack(spacing: 12) {
            // 状态指示灯
            Circle()
                .fill(bridgeService.isLoggedIn ? neonGreen : dangerRed)
                .frame(width: 8, height: 8)
                .shadow(color: bridgeService.isLoggedIn ? neonGreen.opacity(0.8) : dangerRed.opacity(0.8), radius: 6)
            
            Text(bridgeService.connectionStatus)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.gray)
            
            // 登录按钮 (未登录时显示)
            if !bridgeService.isLoggedIn {
                Button(action: { bridgeService.showLoginWindow() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "person.circle")
                        Text("Login")
                    }
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(neonOrange)
                    .foregroundColor(.black)
                    .cornerRadius(4)
                }
                .buttonStyle(ScaleButtonStyle())
                .focusable(false)
            }
            
            Spacer()
            
            // 项目选择器
            Button(action: selectProject) {
                HStack(spacing: 6) {
                    Image(systemName: projectPath.isEmpty ? "folder.badge.plus" : "folder.fill")
                        .font(.system(size: 10))
                        .foregroundColor(projectPath.isEmpty ? neonOrange : .white)
                    Text(projectPath.isEmpty ? "SELECT PROJECT" : URL(fileURLWithPath: projectPath).lastPathComponent.uppercased())
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(projectPath.isEmpty ? neonOrange : .white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 140, alignment: .leading)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(projectPath.isEmpty ? neonOrange.opacity(0.1) : Color.white.opacity(0.05))
                .cornerRadius(6)
            }
            .buttonStyle(ScaleButtonStyle())
            .focusable(false)
            
            // 重启 Bridge 按钮
            Button(action: { bridgeService.startBridge() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
            }
            .buttonStyle(ScaleButtonStyle())
            .focusable(false)
            .help("Restart Bridge")
            
            // Pin 按钮
            Button(action: toggleAlwaysOnTop) {
                Image(systemName: isAlwaysOnTop ? "pin.fill" : "pin")
                    .font(.system(size: 12))
                    .foregroundColor(isAlwaysOnTop ? neonBlue : .gray)
            }
            .buttonStyle(ScaleButtonStyle())
            .focusable(false)
            
            // 关闭按钮
            Button(action: { NSApplication.shared.terminate(nil) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.gray)
            }
            .buttonStyle(ScaleButtonStyle())
            .focusable(false)
        }
        .padding(16)
    }
    
    // MARK: - Project Setup View
    
    private var projectSetupView: some View {
        VStack(spacing: 18) {
            Image(systemName: "bird.fill")
                .font(.system(size: 48))
                .foregroundColor(neonOrange)
                .symbolEffect(.pulse, options: .repeating)
            
            VStack(spacing: 6) {
                Text("SELECT A PROJECT")
                    .font(.system(size: 14, weight: .light, design: .monospaced))
                    .foregroundColor(neonOrange)
                    .tracking(4)
                Text("Choose a directory to start AI pair programming")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.gray.opacity(0.6))
            }
            
            Button(action: selectProject) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                    Text("Select Project Folder")
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(neonOrange)
                .foregroundColor(.black)
                .cornerRadius(8)
            }
            .buttonStyle(ScaleButtonStyle())
            .focusable(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Chat View
    
    private var chatView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(aiderService.messages) { msg in
                        ChatBubble(message: msg, neonBlue: neonBlue)
                            .id(msg.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: aiderService.messages.count) {
                if let lastId = aiderService.messages.last?.id {
                    withAnimation {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
        }
    }
    
    // MARK: - Input Area
    
    private var inputAreaView: some View {
        VStack(spacing: 8) {
            if aiderService.isThinking {
                HStack {
                    ProgressView()
                        .scaleEffect(0.5)
                        .progressViewStyle(CircularProgressViewStyle(tint: neonOrange))
                    Text("Aider is thinking...")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(neonOrange)
                    Spacer()
                }
                .padding(.horizontal)
            }
            
            HStack(alignment: .bottom, spacing: 12) {
                TextEditor(text: $inputText)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(minHeight: 40, maxHeight: 120)
                    .padding(8)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
                    .scrollContentBackground(.hidden)

                Button(action: sendMessage) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 16))
                        .padding(12)
                        .background(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.gray.opacity(0.3) : neonBlue)
                        .foregroundColor(.white)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
        }
        .background(Color.black.opacity(0.4))
        .overlay(Rectangle().frame(height: 1).foregroundColor(Color.white.opacity(0.05)), alignment: .top)
    }
    
    // MARK: - Actions
    
    private func selectProject() {
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Select Root"
            NSApp.activate(ignoringOtherApps: true)
            if panel.runModal() == .OK, let url = panel.url {
                self.projectPath = url.path
                UserDefaults.standard.set(url.path, forKey: "ProjectRoot")
                
                // 更新 GeminiLinkLogic 的项目根目录（触发监听启动）
                GeminiLinkLogic.shared.projectRoot = url.path
                
                // 重启 Aider 使用新路径
                aiderService.stop()
                aiderService.clearMessages()
                aiderService.startAider(projectPath: url.path)
            }
        }
    }
    
    private func sendMessage() {
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        aiderService.sendUserMessage(inputText)
        inputText = ""
    }
    
    private func toggleAlwaysOnTop() {
        if let panel = NSApplication.shared.windows.first(where: { $0 is FloatingPanel }) {
            isAlwaysOnTop.toggle()
            panel.level = isAlwaysOnTop ? .floating : .normal
        }
    }
}

// MARK: - Chat Bubble

struct ChatBubble: View {
    let message: AiderService.ChatMessage
    let neonBlue: Color
    
    var body: some View {
        HStack {
            if message.isUser {
                Spacer()
                Text(message.content)
                    .font(.system(size: 13))
                    .padding(12)
                    .background(neonBlue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                    .frame(maxWidth: 400, alignment: .trailing)
            } else {
                Text(message.content)
                    .font(.system(.body, design: .monospaced))
                    .padding(12)
                    .background(Color.white.opacity(0.05))
                    .foregroundColor(.white.opacity(0.9))
                    .cornerRadius(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                Spacer()
            }
        }
    }
}

// MARK: - Scale Button Style

struct ScaleButtonStyle: ButtonStyle {
func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
            .brightness(configuration.isPressed ? -0.1 : 0)
    }
}
