import SwiftUI

struct ContentView: View {
    @StateObject var logic = GeminiLinkLogic()
    
    var body: some View {
        VStack(spacing: 0) {
            // --- Status Bar ---
            HStack {
                Circle()
                    .fill(logic.isListening ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                    .shadow(color: logic.isListening ? .green : .clear, radius: 4)
                
                Text(logic.isListening ? "Listening" : "Paused")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(logic.isListening ? .green : .secondary)
                
                Spacer()
                
                Button(action: logic.selectProjectRoot) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                        Text(URL(fileURLWithPath: logic.projectRoot).lastPathComponent)
                            .truncationMode(.middle)
                    }
                    .font(.system(size: 10))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.2))
            
            // --- Log Console ---
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(logic.logs) { log in
                        HStack(alignment: .top, spacing: 6) {
                            Text(log.time, style: .time)
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundColor(.secondary)
                            
                            Text(log.message)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(color(for: log.type))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(12)
            }
            .background(Color.black.opacity(0.8))
            
            // --- Actions Grid ---
            VStack(spacing: 1) {
                HStack(spacing: 1) {
                    // Start/Stop
                    Button(action: logic.toggleListening) {
                        Label(logic.isListening ? "Stop" : "Start", systemImage: logic.isListening ? "stop.fill" : "play.fill")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .buttonStyle(TileButtonStyle(active: logic.isListening))
                    
                    // Prep Context
                    Button(action: logic.generateInitContext) {
                        Label("Prep", systemImage: "arrow.up.doc.fill")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .buttonStyle(TileButtonStyle(active: false))
                }
                .frame(height: 36)
                
                HStack(spacing: 1) {
                    // Git Auto Push Toggle
                    Button(action: { logic.autoPush.toggle() }) {
                        Label("Auto Git", systemImage: "icloud.and.arrow.up")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .buttonStyle(TileButtonStyle(active: logic.autoPush))
                    
                    // Magic Paste Toggle
                    Button(action: { logic.magicPaste.toggle() }) {
                        Label("Magic", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .buttonStyle(TileButtonStyle(active: logic.magicPaste))
                    
                    // Verify
                    Button(action: logic.generateVerification) {
                        Label("Verify", systemImage: "checkmark.shield")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .buttonStyle(TileButtonStyle(active: false))
                }
                .frame(height: 36)
            }
            .background(Color.gray.opacity(0.2))
        }
    }
    
    func color(for type: GeminiLinkLogic.LogType) -> Color {
        switch type {
        case .info: return .white
        case .success: return .green
        case .error: return .red
        case .warning: return .yellow
        }
    }
}

// Custom Button Style for the Grid
struct TileButtonStyle: ButtonStyle {
    var active: Bool
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(active ? .white : .secondary)
            .background(active ? Color(red: 0.2, green: 0.5, blue: 0.8) : Color.black.opacity(0.3))
            .overlay(
                Color.white.opacity(configuration.isPressed ? 0.2 : 0)
            )
    }
}
