import SwiftUI

struct ContentView: View {
    @StateObject var logic = GeminiLinkLogic()
    
    var body: some View {
        VStack(spacing: 0) {
            // === 1. Header ===
            HStack {
                // Status Dot
                Circle()
                    .fill(logic.isListening ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                    .shadow(color: logic.isListening ? .green : .clear, radius: 4)
                
                Text(logic.isListening ? "Live" : "Standby")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(logic.isListening ? .green : .secondary)
                
                Spacer()
                
                // Project Path (Clickable)
                Button(action: logic.selectProjectRoot) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                        Text(logic.projectRoot.isEmpty ? "Select Project..." : URL(fileURLWithPath: logic.projectRoot).lastPathComponent)
                            .truncationMode(.middle)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                // Quit Button (Top Right, safe distance)
                Button(action: { NSApplication.shared.terminate(nil) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.gray)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(.ultraThinMaterial)
            
            // === 2. Log Stream ===
            ZStack {
                Color.black.opacity(0.85)
                
                if logic.changeLogs.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 24))
                            .foregroundColor(.gray.opacity(0.5))
                        Text("Ready to Pair")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.gray)
                    }
                } else {
                    List {
                        ForEach(logic.changeLogs) { log in
                            LogRows(log: log, onVerify: {
                                logic.validateCommit(log)
                            }, onToggleStatus: {
                                logic.toggleValidationStatus(for: log.id)
                            })
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .frame(height: 150)
            
            // === 3. Action Bar (Jobs Style) ===
            HStack(spacing: 0) {
                // Button 1: PAIR
                ActionButton(
                    title: "Pair",
                    icon: "link",
                    color: .blue,
                    isActive: false
                ) {
                    logic.copyProtocol()
                }
                
                Divider().frame(height: 24).opacity(0.3)
                
                // Button 2: SYNC (Toggle)
                ActionButton(
                    title: logic.isListening ? "Syncing..." : "Sync",
                    icon: logic.isListening ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath.circle",
                    color: logic.isListening ? .green : .white,
                    isActive: logic.isListening
                ) {
                    logic.toggleListening()
                }
            }
            .frame(height: 48)
            .background(Color(white: 0.15))
        }
        .frame(width: 320)
        .cornerRadius(14)
    }
}

// MARK: - Components

struct ActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let isActive: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                Text(title)
                    .font(.system(size: 12, weight: .bold))
            }
            .foregroundColor(isActive ? .black : color)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(isActive ? color : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct LogRows: View {
    let log: ChangeLog
    let onVerify: () -> Void
    let onToggleStatus: () -> Void
    
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // Commit Hash
            Text(log.commitHash)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.yellow)
                .frame(width: 40, alignment: .leading)
            
            // Summary
            VStack(alignment: .leading, spacing: 2) {
                Text(log.summary)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .foregroundColor(.white)
                Text(log.timestamp, style: .time)
                    .font(.system(size: 8))
                    .foregroundColor(.gray)
            }
            
            Spacer()
            
            // Verify Button
            Button(action: onVerify) {
                Text("Verify")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.blue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.15))
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
            
            // Pass/Fail Status
            Button(action: onToggleStatus) {
                Image(systemName: log.isValidated ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(log.isValidated ? .green : .gray)
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
    }
}
