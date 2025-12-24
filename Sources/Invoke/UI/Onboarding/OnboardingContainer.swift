import SwiftUI

// Environment key for closing onboarding
struct CloseOnboardingKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var closeOnboarding: () -> Void {
        get { self[CloseOnboardingKey.self] }
        set { self[CloseOnboardingKey.self] = newValue }
    }
}

struct OnboardingContainer: View {
    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding: Bool = false
    @StateObject private var permissions = PermissionsManager.shared
    @State private var currentStep = 0
    @State private var selectedMode: GeminiLinkLogic.GitMode = .localOnly
    @Environment(\.closeOnboarding) var closeOnboarding
    
    var body: some View {
        VStack {
            if currentStep == 0 {
                welcomeView
            } else if currentStep == 1 {
                animationDemoView
            } else if currentStep == 2 {
                modeSelectionView
            } else if currentStep == 3 {
                accessibilityPermissionView
            } else if currentStep == 4 {
                gitPermissionsView
            } else if currentStep == 5 {
                geminiSetupView
            }
        }
        .frame(width: 600, height: 520)
        .background(VisualEffectView(material: .popover, blendingMode: .behindWindow))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.3), radius: 20, x: 0, y: 10)
    }
    
    // MARK: - Step 0: Welcome
    var welcomeView: some View {
        VStack(spacing: 30) {
            Spacer()
            
            Image(systemName: "sparkles")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 80, height: 80)
                .foregroundStyle(
                    LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .symbolEffect(.bounce, value: currentStep)
            
            VStack(spacing: 12) {
                Text("Welcome to Invoke")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("AI-powered coding assistant\nSeamlessly integrated with Gemini")
                    .multilineTextAlignment(.center)
                    .font(.body)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button(action: { withAnimation { currentStep = 1 } }) {
                Text("See How It Works")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 60)
            
            Spacer().frame(height: 20)
        }
        .padding()
    }
    
    // MARK: - Step 1: Animation Demo
    var animationDemoView: some View {
        VStack(spacing: 20) {
            Text("How Invoke Works")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("Watch the magic flow")
                .font(.callout)
                .foregroundColor(.secondary)
            
            Spacer().frame(height: 10)
            
            WorkflowAnimationView()
                .frame(height: 280)
            
            Spacer()
            
            Button(action: { withAnimation { currentStep = 2 } }) {
                HStack {
                    Text("Continue")
                    Image(systemName: "arrow.right")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 60)
            
            Button(action: { withAnimation { currentStep = 0 } }) {
                Text("Back")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            
            Spacer().frame(height: 10)
        }
        .padding()
    }
    
    // MARK: - Step 2: Mode Selection
    var modeSelectionView: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 50))
                    .foregroundColor(.blue)
                
                Text("Choose Your Mode")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("You can change this anytime")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            
            VStack(spacing: 12) {
                ModeOptionCard(
                    mode: .localOnly,
                    selected: selectedMode == .localOnly,
                    onSelect: { selectedMode = .localOnly }
                )
                
                ModeOptionCard(
                    mode: .safe,
                    selected: selectedMode == .safe,
                    onSelect: { selectedMode = .safe }
                )
                
                ModeOptionCard(
                    mode: .yolo,
                    selected: selectedMode == .yolo,
                    onSelect: { selectedMode = .yolo }
                )
            }
            .padding(.horizontal)
            
            Spacer()
            
            Button(action: {
                withAnimation { currentStep = 3 }
            }) {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 60)
            
            Button(action: { withAnimation { currentStep = 1 } }) {
                Text("Back")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            
            Spacer().frame(height: 10)
        }
        .padding()
    }
    
    // MARK: - Step 3: Accessibility Permission
    var accessibilityPermissionView: some View {
        VStack(spacing: 24) {
            Spacer()
            
            Image(systemName: "hand.raised.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 70, height: 70)
                .foregroundStyle(
                    LinearGradient(
                        colors: [.orange, .red],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .symbolEffect(.bounce, value: permissions.accessibilityPermission.isGranted)
            
            VStack(spacing: 8) {
                Text("Accessibility Required")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("Essential for auto-paste functionality")
                    .multilineTextAlignment(.center)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            }
            
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: permissions.accessibilityPermission.isGranted ? "checkmark.circle.fill" : "keyboard")
                        .font(.title2)
                        .foregroundColor(permissions.accessibilityPermission.isGranted ? .green : .orange)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Accessibility Permission")
                            .fontWeight(.semibold)
                        Text("Allows Invoke to auto-paste code into browser")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    if permissions.accessibilityPermission.isGranted {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.title2)
                    }
                }
            }
            .padding()
            .background(Color.black.opacity(0.1))
            .cornerRadius(12)
            .padding(.horizontal)
            
            Spacer()
            
            if permissions.accessibilityPermission.isGranted {
                Button(action: {
                    withAnimation { 
                        currentStep = selectedMode.needsGitPermission ? 4 : 5 
                    }
                }) {
                    HStack {
                        Text("Continue")
                        Image(systemName: "arrow.right")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)
                .padding(.horizontal, 60)
            } else {
                Button(action: {
                    permissions.requestAccessibilityPermission()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        permissions.checkAccessibilityPermission()
                    }
                }) {
                    HStack {
                        Image(systemName: "gear")
                        Text("Grant Access")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 60)
                
                Text("Will open System Settings → Privacy & Security → Accessibility")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            
            Button(action: { withAnimation { currentStep = 2 } }) {
                Text("Back")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            
            Spacer().frame(height: 10)
        }
        .padding()
        .onAppear {
            permissions.checkAccessibilityPermission()
        }
    }
    
    // MARK: - Step 4: Git Permissions
    var gitPermissionsView: some View {
        VStack(spacing: 24) {
            Spacer()
            
            Image(systemName: "key.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 70, height: 70)
                .foregroundStyle(
                    LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            
            VStack(spacing: 8) {
                Text("Git Access Required")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("Mode: \(selectedMode.rawValue)")
                    .font(.callout)
                    .foregroundColor(.blue)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(8)
                
                Text("Your selected mode requires Git credentials to push changes")
                    .multilineTextAlignment(.center)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            }
            
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "lock.shield")
                        .font(.title2)
                        .foregroundColor(.blue)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("GitHub/GitLab Credentials")
                            .fontWeight(.semibold)
                        Text("Required for push operations (\(selectedMode.description))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                }
            }
            .padding()
            .background(Color.black.opacity(0.1))
            .cornerRadius(12)
            .padding(.horizontal)
            
            Text("Git credentials will be requested when you first push changes.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Spacer()
            
            Button(action: {
                withAnimation { currentStep = 5 }
            }) {
                HStack {
                    Text("Continue")
                    Image(systemName: "arrow.right")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 60)
            
            Button(action: { withAnimation { currentStep = 3 } }) {
                Text("Back")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            
            Spacer().frame(height: 10)
        }
        .padding()
    }
    
    // MARK: - Step 5: Gemini Setup (Redesigned & Premium)
    var geminiSetupView: some View {
        VStack(spacing: 0) {
            // Header Section
            VStack(spacing: 16) {
                // Icons connection animation
                HStack(spacing: 16) {
                    if #available(macOS 15.0, *) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 36))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.purple, .blue],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .symbolEffect(.bounce, options: .nonRepeating)
                    } else {
                        // Fallback for macOS 14
                        Image(systemName: "sparkles")
                            .font(.system(size: 36))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.purple, .blue],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                    
                    Image(systemName: "arrow.right")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.3))
                    
                    Image(systemName: "link.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.blue, .cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .padding(.top, 40)
                
                VStack(spacing: 8) {
                    Text("Final Step")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.secondary)
                        .tracking(1.5)
                        .textCase(.uppercase)
                    
                    Text("Connect Repository")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                }
            }
            
            Spacer()
            
            // Instructions List - Clean Design without cards
            VStack(alignment: .leading, spacing: 24) {
                stepRow(num: 1, text: "Open **gemini.google.com**")
                stepRow(num: 2, text: "Start a new conversation")
                stepRow(num: 3, text: "Click the **Attachment (📎)** icon")
                stepRow(num: 4, text: "Select **'Add GitHub repository'**")
                stepRow(num: 5, text: "Connect your project repository")
            }
            .padding(.horizontal, 40)
            
            Spacer()
            
            // Footer Info
            HStack(spacing: 6) {
                Image(systemName: "magic")
                    .font(.caption)
                Text("Enables real-time code context access")
                    .font(.caption)
            }
            .foregroundColor(.secondary)
            .padding(.bottom, 20)
            
            // Action Button
            Button(action: {
                UserDefaults.standard.set(selectedMode.rawValue, forKey: "GitMode")
                hasCompletedOnboarding = true
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    closeOnboarding()
                }
            }) {
                HStack {
                    Text("Start Coding")
                        .fontWeight(.bold)
                    Image(systemName: "arrow.right")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    LinearGradient(
                        colors: [Color(red: 0.2, green: 0.8, blue: 0.5), Color(red: 0.1, green: 0.7, blue: 0.4)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .foregroundColor(.white)
                .cornerRadius(14)
                .shadow(color: Color.green.opacity(0.3), radius: 10, y: 5)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 40)
            .padding(.bottom, 40)
        }
    }
    
    // Helper View Builder for Clean Steps
    private func stepRow(num: Int, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text("\(num)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.blue.opacity(0.8)))
                .shadow(color: .blue.opacity(0.3), radius: 4, y: 2)
            
            Text(.init(text)) // Init with Markdown for bold support
                .font(.system(size: 15, weight: .medium, design: .default))
                .foregroundColor(.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true) // Prevents truncation
                .lineLimit(nil)
            
            Spacer()
        }
    }
}