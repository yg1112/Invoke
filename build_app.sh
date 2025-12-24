import SwiftUI
import ApplicationServices

struct ContentView: View {
    @StateObject var logic = GeminiLinkLogic()
    @State private var isAlwaysOnTop = true
    @State private var hasPermission = AXIsProcessTrusted()
    
    // 🎨 Fetch Palette
    let darkBg = Color(red: 0.05, green: 0.05, blue: 0.07)
    let neonGreen = Color(red: 0.0, green: 0.9, blue: 0.5)
    let neonBlue = Color(red: 0.0, green: 0.5, blue: 1.0)
    let neonOrange = Color(red: 1.0, green: 0.6, blue: 0.0)
    let dangerRed = Color(red: 1.0, green: 0.3, blue: 0.4)
    
    let smartFont = Font.system(size: 14, weight: .light, design: .monospaced)
    let permissionTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
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
                HStack(spacing: 12) {
                    // 1. 状态灯
                    StatusIndicator(status: currentStatus, color: statusColor)
                    
                    // 2. 项目选择器
                    ProjectSelector(logic: logic, color: neonOrange)
                    
                    Spacer()
                    
                    // 3. 🔥 全新设计的 Mode Selector (带解释的菜单)
                    Menu {
                        ForEach(GeminiLinkLogic.GitMode.allCases, id: \.self) { mode in
                            Button(action: { logic.gitMode = mode }) {
                                HStack {
                                    if logic.gitMode == mode { Image(systemName: "checkmark") }
                                    Text(mode.title)
                                    Image(systemName: mode.icon)
                                    // 菜单里的解释文本，让用户秒懂
                                    Text("- " + mode.description).font(.caption)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: logic.gitMode.icon)
                                .font(.system(size: 10))
                            Text(logic.gitMode.title.uppercased())
                                .font(.system(size: 10, weight: .bold))
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 8))
                                .opacity(0.5)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(6)
                        .foregroundColor(.white.opacity(0.8))
                    }
                    .menuStyle(.borderlessButton)
                    .focusable(false)
                    .help(logic.gitMode.description)
                    
                    // 4. Pin & Close
                    WindowControls(isAlwaysOnTop: $isAlwaysOnTop, toggleAction: toggleAlwaysOnTop)
                }
                .padding(16)
                
                // === PROCESSING BANNER ===
                if logic.isProcessing {
                    ProcessingBanner(status: logic.processingStatus, color: neonOrange)
                }
                
                // === CONTENT ===
                Group {
                    if !hasPermission {
                        EmptyStateView(
                            status: .error,
                            neonColor: neonGreen, orangeColor: neonOrange, dangerColor: dangerRed,
                            smartFont: smartFont, onFixAction: openAccessibilitySettings
                        )
                    } else if logic.changeLogs.isEmpty {
                        EmptyStateView(
                            status: currentStatus,
                            neonColor: neonGreen, orangeColor: neonOrange, dangerColor: dangerRed,
                            smartFont: smartFont, onFixAction: openAccessibilitySettings
                        )
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 8) {
                                ForEach(logic.changeLogs) { log in
                                    TransactionCard(log: log, logic: logic)
                                        .transition(.scale.combined(with: .opacity))
                                }
                            }
                            .padding(16)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                
                // === FOOTER ===
                HStack(spacing: 16) {
                    Menu {
                        Button("📋 Copy @code Protocol") { logic.copyProtocol() }
                        Button("⚙️ First Time Setup") { logic.copyGemSetupGuide() }
                        Button("🔒 Check Permissions") { openAccessibilitySettings() }
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
                    .focusable(false)
                    
                    Spacer()
                    
                    HStack(spacing: 8) {
                        GhostActionButton(title: "Apply", icon: "arrow.down", activeColor: neonGreen) {
                            logic.manualApplyFromClipboard()
                        }
                        GhostActionButton(title: "Review", icon: "eye", activeColor: neonOrange) {
                            logic.reviewLastChange()
                        }
                    }
                }
                .padding(16)
                .background(Color.black.opacity(0.4))
                .overlay(Rectangle().frame(height: 1).foregroundColor(Color.white.opacity(0.05)), alignment: .top)
            }
        }
        .frame(minWidth: 480, maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
        .cornerRadius(16)
        .onAppear {
            toggleAlwaysOnTop()
            hasPermission = AXIsProcessTrusted()
        }
        .onReceive(permissionTimer) { _ in hasPermission = AXIsProcessTrusted() }
    }
    
    // Status Logic
    enum AppStatus { case error, warning, processing, ready }
    var currentStatus: AppStatus {
        if !hasPermission { return .error }
        if logic.isProcessing { return .processing }
        if logic.projectRoot.isEmpty { return .warning }
        return .ready
    }
    var statusColor: Color {
        switch currentStatus {
        case .error: return dangerRed
        case .warning, .processing: return neonOrange
        case .ready: return neonGreen
        }
    }
    var statusDescription: String {
        switch currentStatus {
        case .error: return "Missing Permissions"
        case .warning: return "No Target Selected"
        case .processing: return "Processing..."
        case .ready: return "Listening..."
        }
    }
    
    private func toggleAlwaysOnTop() {
        if let panel = NSApplication.shared.windows.first(where: { $0 is FloatingPanel }) {
            panel.level = isAlwaysOnTop ? .floating : .normal
        }
    }
    
    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Subcomponents (Keep code clean)

struct StatusIndicator: View {
    let status: ContentView.AppStatus
    let color: Color
    
    var body: some View {
        ZStack {
            if status != .ready {
                Circle().fill(color.opacity(0.3)).frame(width: 12, height: 12)
                    .scaleEffect(1.5)
                    .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: status)
            }
            Circle().fill(color).frame(width: 8, height: 8).shadow(color: color.opacity(0.8), radius: 6)
        }.frame(width: 16)
    }
}

struct ProjectSelector: View {
    @ObservedObject var logic: GeminiLinkLogic
    let color: Color
    
    var body: some View {
        Button(action: logic.selectProjectRoot) {
            HStack(spacing: 6) {
                Image(systemName: logic.projectRoot.isEmpty ? "folder.badge.plus" : "folder.fill")
                    .font(.system(size: 10))
                    .foregroundColor(logic.projectRoot.isEmpty ? color : .white)
                
                Text(logic.projectRoot.isEmpty ? "SELECT TARGET" : URL(fileURLWithPath: logic.projectRoot).lastPathComponent.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(logic.projectRoot.isEmpty ? color : .white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 140, alignment: .leading)
                
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundColor(.white.opacity(0.3))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(logic.projectRoot.isEmpty ? color.opacity(0.1) : Color.white.opacity(0.05))
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(logic.projectRoot.isEmpty ? color.opacity(0.3) : Color.white.opacity(0.1), lineWidth: 0.5))
            .symbolEffect(.pulse, isActive: logic.projectRoot.isEmpty)
        }.buttonStyle(ScaleButtonStyle()).focusable(false)
    }
}

struct WindowControls: View {
    @Binding var isAlwaysOnTop: Bool
    let toggleAction: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggleAction) {
                Image(systemName: isAlwaysOnTop ? "pin.fill" : "pin").font(.system(size: 12))
                    .foregroundColor(isAlwaysOnTop ? Color.blue : .gray)
            }.buttonStyle(ScaleButtonStyle()).focusable(false)
            
            Button(action: { NSApplication.shared.terminate(nil) }) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundColor(.gray)
            }.buttonStyle(ScaleButtonStyle()).focusable(false)
        }
    }
}

struct ProcessingBanner: View {
    let status: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().scaleEffect(0.6).progressViewStyle(CircularProgressViewStyle(tint: color))
            Text(status.uppercased()).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(color)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct TransactionCard: View {
    let log: ChangeLog
    @ObservedObject var logic: GeminiLinkLogic
    @State private var isHovering = false
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.white.opacity(0.05)).frame(width: 32, height: 32)
                Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .bold)).foregroundColor(.white.opacity(0.7))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(log.summary).font(.system(size: 13, weight: .medium)).foregroundColor(.white).lineLimit(1)
                HStack(spacing: 6) {
                    Text(log.commitHash).font(.system(size: 10, design: .monospaced)).foregroundColor(.gray).padding(.horizontal, 4).background(Color.white.opacity(0.05)).cornerRadius(4)
                    Text(timeAgo(log.timestamp)).font(.system(size: 10)).foregroundColor(.gray.opacity(0.7))
                }
            }
            Spacer()
            if isHovering {
                HStack(spacing: 4) {
                    Button(action: openCommit) {
                        Image(systemName: "safari").foregroundColor(.blue).frame(width: 28, height: 28).background(Color.blue.opacity(0.1)).clipShape(Circle())
                    }.buttonStyle(ScaleButtonStyle()).focusable(false)
                    Button(action: { logic.closePR(for: log) }) {
                        Image(systemName: "xmark").foregroundColor(.red).frame(width: 28, height: 28).background(Color.red.opacity(0.1)).clipShape(Circle())
                    }.buttonStyle(ScaleButtonStyle()).focusable(false)
                }.transition(.scale.combined(with: .opacity))
            }
        }
        .padding(10)
        .background(isHovering ? Color.white.opacity(0.08) : Color.white.opacity(0.03))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isHovering ? Color.white.opacity(0.1) : Color.clear, lineWidth: 1))
        .onHover { hover in withAnimation(.easeInOut(duration: 0.2)) { isHovering = hover } }
    }
    private func openCommit() {
        if let str = GitService.shared.getCommitURL(for: log.commitHash, in: logic.projectRoot), let url = URL(string: str) { NSWorkspace.shared.open(url) }
    }
    private func timeAgo(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter(); formatter.unitsStyle = .abbreviated; return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct GhostActionButton: View {
    let title: String; let icon: String; let activeColor: Color; let action: () -> Void
    @State private var isHovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) { Image(systemName: icon).font(.system(size: 11, weight: .bold)); Text(title.uppercased()).font(.system(size: 11, weight: .bold)) }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(isHovering ? activeColor : Color.white.opacity(0.05))
                .foregroundColor(isHovering ? .black : .gray)
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(isHovering ? activeColor : Color.white.opacity(0.1), lineWidth: 1))
                .shadow(color: isHovering ? activeColor.opacity(0.4) : .clear, radius: 6, x: 0, y: 2)
        }.buttonStyle(ScaleButtonStyle()).focusable(false)
        .onHover { hover in withAnimation(.easeInOut(duration: 0.15)) { isHovering = hover } }
    }
}

struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.95 : 1).animation(.easeInOut(duration: 0.1), value: configuration.isPressed).brightness(configuration.isPressed ? -0.1 : 0)
    }
}

struct EmptyStateView: View {
    let status: ContentView.AppStatus
    let neonColor: Color; let orangeColor: Color; let dangerColor: Color
    let smartFont: Font; let onFixAction: () -> Void
    
    var body: some View {
        VStack(spacing: 18) {
            Button(action: { if status == .error { onFixAction() } }) { birdIcon }.buttonStyle(.plain).focusable(false)
                .onHover { inside in if inside && status == .error { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
            VStack(spacing: 6) {
                Text(statusText).font(smartFont).foregroundColor(statusTextColor).tracking(4)
                Text(subStatusText).font(.system(size: 10, weight: .medium)).foregroundColor(.gray.opacity(0.6))
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { if status == .error { onFixAction() } }
    }
    
    var birdIcon: some View {
        Group {
            if #available(macOS 15.0, *) {
                Image(systemName: "bird.fill").font(.system(size: 48)).foregroundColor(statusTextColor)
                    .symbolEffect(.wiggle, options: .repeating, isActive: status == .ready)
                    .symbolEffect(.pulse, options: .repeating, isActive: status == .error)
            } else {
                Image(systemName: "bird.fill").font(.system(size: 48)).foregroundColor(statusTextColor)
                    .symbolEffect(.bounce, options: .repeating, isActive: status == .ready)
                    .symbolEffect(.pulse, options: .repeating, isActive: status == .error)
            }
        }
    }
    
    var statusText: String {
        switch status {
        case .ready: return "AWAITING SEEDS"
        case .error: return "ACCESS LOCKED"
        case .warning: return "NEED A HOME"
        case .processing: return "DIGESTING..."
        }
    }
    
    var statusTextColor: Color {
        switch status {
        case .ready: return neonColor
        case .error: return dangerColor
        case .warning, .processing: return orangeColor
        }
    }
    
    var subStatusText: String {
        switch status {
        case .ready: return "Copy code to feed codebase"
        case .error: return "Click bird to unlock permissions"
        case .warning: return "Select project target above"
        case .processing: return "Applying changes..."
        }
    }
}