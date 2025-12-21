import SwiftUI

struct ContentView: View {
    @StateObject var logic = GeminiLinkLogic()
    
    var body: some View {
        VStack(spacing: 0) {
            // === 1. Top Bar: Project & Status ===
            HStack {
                // Status Light
                Circle()
                    .fill(logic.isListening ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                    .shadow(color: logic.isListening ? .green : .clear, radius: 4)
                
                Text(logic.isListening ? "Running" : "Paused")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(logic.isListening ? .green : .secondary)
                
                Spacer()
                
                // Project Selector
                Button(action: logic.selectProjectRoot) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                        Text(logic.projectRoot.isEmpty ? "Select Project" : URL(fileURLWithPath: logic.projectRoot).lastPathComponent)
                            .truncationMode(.middle)
                    }
                    .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .padding(4)
                .background(Color.white.opacity(0.1))
                .cornerRadius(4)
            }
            .padding(10)
            .background(.ultraThinMaterial)
            
            // === 2. Middle: Log List ===
            ZStack {
                Color.black.opacity(0.8)
                
                if logic.changeLogs.isEmpty {
                    VStack(spacing: 6) {
                        Text("Ready to Code")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                        Text("Step 1: Click 'Copy Context' & paste to Gemini.\nStep 2: Turn on 'Auto-Paste Mode'.")
                            .font(.system(size: 10))
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                    }
                } else {
                    List {
                        ForEach(logic.changeLogs) { log in
                            LogRows(log: log, onValidate: {
                                logic.validateCommit(log)
                            }, onToggleStatus: {
                                logic.toggleValidationStatus(for: log.id)
                            })
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .frame(height: 140)
            
            // === 3. Bottom: Action Buttons ===
            HStack(spacing: 0) {
                // Button 1: Copy Context
                WorkflowButton(icon: "doc.on.doc.fill", label: "1. Copy Context", color: .blue) {
                    logic.copyProtocol()
                }
                
                Divider().frame(height: 20)
                
                // Button 2: Auto-Paste Mode
                WorkflowButton(
                    icon: logic.isListening ? "pause.circle.fill" : "play.circle.fill",
                    label: logic.isListening ? "Stop" : "2. Auto-Paste Mode",
                    color: logic.isListening ? .green : .gray
                ) {
                    logic.toggleListening()
                }
                
                Divider().frame(height: 20)
                
                // Quit Button (Replacement for Settings)
                Button(action: { NSApplication.shared.terminate(nil) }) {
                    Image(systemName: "power")
                        .font(.system(size: 10))
                        .foregroundColor(.red.opacity(0.8))
                        .frame(width: 30, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Quit App")
            }
            .frame(height: 40)
            .background(Color.gray.opacity(0.1))
        }
        .frame(width: 340) // Slightly wider for better text fit
        .cornerRadius(12)
    }
}

// MARK: - Subviews

struct LogRows: View {
    let log: ChangeLog
    let onValidate: () -> Void
    let onToggleStatus: () -> Void
    
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // Commit Hash
            Text(log.commitHash)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.yellow)
                .frame(width: 45, alignment: .leading)
            
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
            
            // Validation Controls
            HStack(spacing: 0) {
                Button(action: onValidate) {
                    HStack(spacing: 2) {
                        Image(systemName: "magnifyingglass")
                        Text("Check")
                    }
                    .font(.system(size: 9))
                    .foregroundColor(.blue)
                    .padding(3)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help("Ask Gemini to validate this commit")
                .padding(.trailing, 8)
                
                Button(action: onToggleStatus) {
                    Text(log.isValidated ? "PASS" : "WAIT")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(log.isValidated ? .green : .orange)
                        .frame(width: 30)
                        .padding(2)
                        .background(log.isValidated ? Color.green.opacity(0.2) : Color.orange.opacity(0.2))
                        .cornerRadius(3)
                }
                .buttonStyle(.plain)
            }
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
    }
}

struct WorkflowButton: View {
    let icon: String
    let label: String
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(label)
            }
            .font(.system(size: 11, weight: .medium))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .foregroundColor(color)
        .onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
