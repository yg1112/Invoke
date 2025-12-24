import SwiftUI

struct ContentView: View {
    @StateObject var logic = GeminiLinkLogic()
    @State private var isAlwaysOnTop = false
    
    // 🎨 Robinhood / Cyberpunk Palette
    let darkBg = Color(red: 0.05, green: 0.05, blue: 0.07) // 近乎全黑
    let neonGreen = Color(red: 0.0, green: 0.9, blue: 0.5) // Robinhood Green
    let neonBlue = Color(red: 0.0, green: 0.5, blue: 1.0)
    let neonOrange = Color(red: 1.0, green: 0.6, blue: 0.0)
    
    var body: some View {
        ZStack {
            // 1. 沉浸式暗黑背景
            darkBg.opacity(0.95)
                .edgesIgnoringSafeArea(.all)
            
            // 2. 细微的边框光晕 (Border Glow)
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
                HStack(spacing: 16) {
                    // 状态指示器 (呼吸灯效果)
                    ZStack {
                        Circle()
                            .fill(statusColor.opacity(0.2))
                            .frame(width: 12, height: 12)
                            .scaleEffect(logic.isProcessing || logic.isListening ? 1.5 : 1.0)
                            .opacity(logic.isProcessing || logic.isListening ? 0 : 1)
                            .animation(
                                (logic.isProcessing || logic.isListening) ?
                                    Animation.easeOut(duration: 1.5).repeatForever(autoreverses: false) : .default,
                                value: logic.isProcessing || logic.isListening
                            )
                        
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                            .shadow(color: statusColor.opacity(0.8), radius: 6)
                    }
                    .frame(width: 16) // 固定占位
                    
                    // 项目选择器 (Project Selector) - 交互升级版
                    Button(action: logic.selectProjectRoot) {
                        HStack(spacing: 6) {
                            // 1. 图标变化：没选项目时显示加号文件夹，更有行动导向
                            Image(systemName: logic.projectRoot.isEmpty ? "folder.badge.plus" : "folder.fill")
                                .font(.system(size: 10))
                                .foregroundColor(logic.projectRoot.isEmpty ? neonOrange : .white)
                            
                            // 2. 文字内容
                            Text(logic.projectRoot.isEmpty ? "SELECT TARGET" : URL(fileURLWithPath: logic.projectRoot).lastPathComponent.uppercased())
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(logic.projectRoot.isEmpty ? neonOrange : .white)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 160, alignment: .leading) // 限制最大宽度，防止挤压
                            
                            // 3. 关键修复：添加下拉箭头，告诉用户"这里可以点"
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.white.opacity(0.3)) // 微弱显示，不抢戏
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        // 4. 背景：未选择时显示微弱的橙色背景提示
                        .background(
                            logic.projectRoot.isEmpty 
                            ? neonOrange.opacity(0.1) 
                            : Color.white.opacity(0.05)
                        )
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(
                                    logic.projectRoot.isEmpty ? neonOrange.opacity(0.3) : Color.white.opacity(0.1),
                                    lineWidth: 0.5
                                )
                        )
                        // 5. 动画：未选择时，边框会有呼吸效果，吸引注意力
                        .symbolEffect(.pulse, isActive: logic.projectRoot.isEmpty)
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .help("Change target repository")
                    
                    Spacer()
                    
                    // Pin & Close (极简图标)
                    HStack(spacing: 12) {
                        Button(action: toggleAlwaysOnTop) {
                            Image(systemName: isAlwaysOnTop ? "pin.fill" : "pin")
                                .font(.system(size: 12))
                                .foregroundColor(isAlwaysOnTop ? neonBlue : .gray)
                        }
                        .buttonStyle(ScaleButtonStyle())
                        
                        Button(action: { NSApplication.shared.terminate(nil) }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.gray)
                        }
                        .buttonStyle(ScaleButtonStyle())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)
                
                // === MODE SELECTOR (Segmented Neon) ===
                HStack(spacing: 2) {
                    ForEach(GeminiLinkLogic.GitMode.allCases, id: \.self) { mode in
                        let isSelected = logic.gitMode == mode
                        Button(action: { withAnimation { logic.gitMode = mode } }) {
                            Text(mode.rawValue)
                                .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                                .foregroundColor(isSelected ? .white : .gray)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(isSelected ? Color.white.opacity(0.1) : Color.clear)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Color.black.opacity(0.3))
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.05), lineWidth: 1))
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                
                // === PROCESSING BANNER ===
                if logic.isProcessing {
                    HStack(spacing: 10) {
                        ProgressView()
                            .scaleEffect(0.6)
                            .progressViewStyle(CircularProgressViewStyle(tint: neonOrange))
                        
                        Text(logic.processingStatus.uppercased())
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(neonOrange)
                        
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                
                // === ACTIVITY STREAM (Cards) ===
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if logic.changeLogs.isEmpty {
                            EmptyStateView(isListening: logic.isListening)
                                .frame(height: 150)
                        } else {
                            ForEach(logic.changeLogs) { log in
                                TransactionCard(log: log, logic: logic)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
                
                // === CONTROL DECK (Footer) ===
                HStack(spacing: 16) {
                    // Magic Button (Pair)
                    Menu {
                        Button("📋 Copy @code Protocol") { logic.copyProtocol() }
                        Button("⚙️ First Time Setup") { logic.copyGemSetupGuide() }
                    } label: {
                        HStack {
                            Image(systemName: "sparkles")
                            Text("PAIR")
                        }
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(neonBlue)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(neonBlue.opacity(0.1))
                        .cornerRadius(8)
                    }
                    .menuStyle(.borderlessButton)
                    
                    Spacer()
                    
                    // Main Action Buttons
                    HStack(spacing: 8) {
                        ActionButton(title: "Apply", icon: "arrow.down", color: neonGreen) {
                            logic.manualApplyFromClipboard()
                        }
                        
                        ActionButton(title: "Review", icon: "eye", color: neonOrange) {
                            logic.reviewLastChange()
                        }
                    }
                }
                .padding(16)
                .background(Color.black.opacity(0.4))
                .overlay(Rectangle().frame(height: 1).foregroundColor(Color.white.opacity(0.05)), alignment: .top)
            }
        }
        .frame(minWidth: 460, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
        .cornerRadius(16)
    }
    
    // Helper: Dynamic Status Color
    var statusColor: Color {
        if logic.isProcessing { return neonOrange }
        if logic.isListening { return neonGreen }
        return .gray
    }
    
    private func toggleAlwaysOnTop() {
        isAlwaysOnTop.toggle()
        if let panel = NSApplication.shared.windows.first(where: { $0 is FloatingPanel }) {
            panel.level = isAlwaysOnTop ? .statusBar : .normal
        }
    }
}

// MARK: - Transaction Card (The "Robinhood" Row)
struct TransactionCard: View {
    let log: ChangeLog
    @ObservedObject var logic: GeminiLinkLogic
    @State private var isHovering = false
    
    var body: some View {
        HStack(spacing: 12) {
            // Icon Stack
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.05))
                    .frame(width: 32, height: 32)
                
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white.opacity(0.7))
            }
            
            // Content
            VStack(alignment: .leading, spacing: 2) {
                Text(log.summary)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                
                HStack(spacing: 6) {
                    Text(log.commitHash)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.gray)
                        .padding(.horizontal, 4)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(4)
                    
                    Text(timeAgo(log.timestamp))
                        .font(.system(size: 10))
                        .foregroundColor(.gray.opacity(0.7))
                }
            }
            
            Spacer()
            
            // Actions (Reveal on Hover)
            if isHovering {
                HStack(spacing: 4) {
                    // Open GitHub
                    Button(action: openCommit) {
                        Image(systemName: "safari")
                            .foregroundColor(.blue)
                            .frame(width: 28, height: 28)
                            .background(Color.blue.opacity(0.1))
                            .clipShape(Circle())
                    }
                    .buttonStyle(ScaleButtonStyle())
                    
                    // Close/Delete
                    Button(action: { logic.closePR(for: log) }) { // Added Close Action
                        Image(systemName: "xmark")
                            .foregroundColor(.red)
                            .frame(width: 28, height: 28)
                            .background(Color.red.opacity(0.1))
                            .clipShape(Circle())
                    }
                    .buttonStyle(ScaleButtonStyle())
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(10)
        .background(isHovering ? Color.white.opacity(0.08) : Color.white.opacity(0.03))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isHovering ? Color.white.opacity(0.1) : Color.clear, lineWidth: 1)
        )
        .onHover { hover in withAnimation(.easeInOut(duration: 0.2)) { isHovering = hover } }
    }
    
    private func openCommit() {
        if let str = GitService.shared.getCommitURL(for: log.commitHash, in: logic.projectRoot),
           let url = URL(string: str) {
            NSWorkspace.shared.open(url)
        }
    }
    
    private func timeAgo(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Action Button
struct ActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(color)
            .foregroundColor(.black)
            .cornerRadius(8)
            .shadow(color: color.opacity(0.4), radius: 6, x: 0, y: 2)
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

// MARK: - Custom Button Style (Haptic Feel)
struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
            .brightness(configuration.isPressed ? -0.1 : 0)
    }
}

// MARK: - Empty State
struct EmptyStateView: View {
    let isListening: Bool
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: isListening ? "waveform.path.ecg" : "bolt.slash.fill")
                .font(.system(size: 40))
                .foregroundColor(isListening ? Color(red: 0.0, green: 0.9, blue: 0.5).opacity(0.5) : .gray.opacity(0.3))
                .symbolEffect(.pulse, isActive: isListening)
            
            Text(isListening ? "LISTENING FOR CODE" : "READY TO SYNC")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.gray)
                .tracking(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
