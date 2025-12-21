import SwiftUI
import AppKit
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var floatingPanel: FloatingPanel?
    var settingsWindow: NSWindow?
    var onboardingWindow: NSWindow?
    
    private var cancellables = Set<AnyCancellable>()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("✅ [APP] Launching Invoke")
        
        setupMenuBarIcon()
        
        let needsOnboarding = !UserDefaults.standard.bool(forKey: "HasCompletedOnboardingV1")
        
        if needsOnboarding {
            showOnboardingWindow()
        } else {
            finishLaunch()
        }
    }
    
    private func setupMenuBarIcon() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem?.button {
            let icon = NSImage(systemSymbolName: "hand.rays.fill", accessibilityDescription: "Invoke")
            icon?.size = NSSize(width: 18, height: 18)
            button.image = icon
            button.action = #selector(togglePanel)
            button.target = self
        }
        
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Panel", action: #selector(showPanel), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        
        statusItem?.menu = menu
    }
    
    @objc private func togglePanel() {
        if let panel = floatingPanel, panel.isVisible {
            panel.orderOut(nil)
        } else {
            floatingPanel?.orderFront(nil)
        }
    }
    
    @objc private func showPanel() {
        floatingPanel?.orderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    private func showOnboardingWindow() {
        let onboardingView = OnboardingContainer {
            self.onboardingWindow?.close()
            self.onboardingWindow = nil
            UserDefaults.standard.set(true, forKey: "HasCompletedOnboardingV1")
            self.finishLaunch()
            print("🔄 [APP] Onboarding complete.")
        }
        
        let hostingView = NSHostingView(rootView: onboardingView)
        let windowSize = NSSize(width: 800, height: 600)
        hostingView.frame = NSRect(origin: .zero, size: windowSize)
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor.clear
        window.isOpaque = false
        window.hasShadow = true
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        
        self.onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    private func finishLaunch() {
        print("🚀 [APP] Finishing launch sequence")
        
        let contentRect = NSRect(x: 0, y: 0, width: 280, height: 120)
        floatingPanel = FloatingPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        if let panel = floatingPanel {
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            
            let appUI = AppUI(
                onSettings: { [weak self] in self?.showSettings() },
                onQuit: { NSApplication.shared.terminate(nil) }
            )
            
            let hostingView = NSHostingView(rootView: appUI)
            hostingView.frame = contentRect
            hostingView.wantsLayer = true
            hostingView.layer?.backgroundColor = NSColor.clear.cgColor
            
            panel.contentView = hostingView
            panel.orderFront(nil)
        }
    }
    
    @objc func showSettings() {
        if settingsWindow == nil {
            let settingsView = SettingsView()
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: NSSize(width: 400, height: 300)),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            
            window.title = "Settings"
            window.titleVisibility = .hidden
            window.contentView = NSHostingView(rootView: settingsView)
            window.center()
            window.isReleasedWhenClosed = false
            window.level = .floating
            
            settingsWindow = window
        }
        
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    var body: some View {
        VStack(spacing: 20) {
            Text("Settings")
                .font(.system(size: 18, weight: .bold))
            
            Divider()
            
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Version")
                        .font(.system(size: 13))
                    Spacer()
                    Text("1.0")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("Automatically check for updates")
                        .font(.system(size: 13))
                    Spacer()
                    Toggle("", isOn: .constant(true))
                }
            }
            
            Spacer()
        }
        .padding(20)
        .frame(minWidth: 300)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
