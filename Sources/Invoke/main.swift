import SwiftUI
import AppKit
import Combine

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem?
    var floatingPanel: FloatingPanel?
    var onboardingWindow: NSWindow?
    
    let posKeyX = "WindowPosX"
    let posKeyY = "WindowPosY"
    let widthKey = "WindowWidth"
    let heightKey = "WindowHeight"
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBarIcon()
        
        if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            showOnboarding()
        } else {
            setupFloatingPanel()
        }
    }
    
    private func setupMenuBarIcon() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            // 🐦 品牌重塑：图标改为小鸟
            button.image = NSImage(systemSymbolName: "bird.fill", accessibilityDescription: "Fetch")
            button.action = #selector(togglePanel)
            button.target = self
        }
    }
    
    private func setupFloatingPanel() {
        let defaultW: CGFloat = 480
        let defaultH: CGFloat = 320
        
        let w = UserDefaults.standard.double(forKey: widthKey)
        let h = UserDefaults.standard.double(forKey: heightKey)
        let finalW = w > 0 ? CGFloat(w) : defaultW
        let finalH = h > 0 ? CGFloat(h) : defaultH
        
        let savedX = UserDefaults.standard.double(forKey: posKeyX)
        let savedY = UserDefaults.standard.double(forKey: posKeyY)
        let x = savedX != 0 ? CGFloat(savedX) : 100
        let y = savedY != 0 ? CGFloat(savedY) : 100
        
        let contentRect = NSRect(x: x, y: y, width: finalW, height: finalH)
        
        floatingPanel = FloatingPanel(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        if let panel = floatingPanel {
            panel.delegate = self
            panel.level = .floating 
            panel.titlebarAppearsTransparent = true
            panel.titleVisibility = .hidden
            panel.isMovableByWindowBackground = true
            panel.standardWindowButton(.closeButton)?.isHidden = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.minSize = NSSize(width: 380, height: 200)
            
            let appUI = AppUI(
                onSettings: {},
                onQuit: { NSApplication.shared.terminate(nil) }
            )
            
            let hostingView = NSHostingView(rootView: appUI)
            hostingView.autoresizingMask = [.width, .height]
            hostingView.frame = NSRect(x: 0, y: 0, width: finalW, height: finalH)
            hostingView.layer?.backgroundColor = NSColor.clear.cgColor
            
            panel.contentView = hostingView
            panel.orderFront(nil)
        }
    }
    
    func windowDidMove(_ notification: Notification) { saveWindowFrame() }
    func windowDidResize(_ notification: Notification) { saveWindowFrame() }
    
    private func saveWindowFrame() {
        guard let panel = floatingPanel else { return }
        UserDefaults.standard.set(Double(panel.frame.origin.x), forKey: posKeyX)
        UserDefaults.standard.set(Double(panel.frame.origin.y), forKey: posKeyY)
        UserDefaults.standard.set(Double(panel.frame.size.width), forKey: widthKey)
        UserDefaults.standard.set(Double(panel.frame.size.height), forKey: heightKey)
    }
    
    @objc private func togglePanel() {
        guard let panel = floatingPanel else { return }
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    }
    
    private func showOnboarding() {
        let onboardingView = OnboardingContainer().environment(\.closeOnboarding, { [weak self] in
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
            self?.setupFloatingPanel()
        })
        onboardingWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 520), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        onboardingWindow?.center()
        onboardingWindow?.titlebarAppearsTransparent = true
        onboardingWindow?.contentView = NSHostingView(rootView: onboardingView)
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()